# Grid Panel — wire protocol

Normative. Everything here is implemented twice with no shared code — `device/esp32-circle/main/panel_frame.c` on the
device and `lib/infrastructure/panel/panel_frame.dart` + `panel_message.dart` in the app — so this
document is the only place the two agree by construction rather than by coincidence.

Two layers, versioned separately:

- **Framing** turns a byte stream into messages. Version 1.
- **Messages** are what the two sides say to each other. Version 1.

They are separate because they change for different reasons. Adding a message is a message-layer
change and needs no reflash of anything that only forwards bytes; changing the envelope is a
framing change and breaks every reader. Conflating them makes the cheap change look as expensive as
the expensive one.

---

## 1. Framing

### Layout

Little-endian throughout.

```
offset  size  field
     0     2  magic      A5 5A
     2     1  version    framing version, currently 1
     3     1  type       payload kind (below)
     4     2  length     payload bytes, u16
     6   len  payload
 6+len     2  crc16      CRC-16/CCITT-FALSE over bytes [2, 6+len)
```

Overhead is 8 bytes. Maximum payload is **8192**, so a frame never exceeds 8200 bytes.

The CRC covers version, type, length and payload — not the magic. The magic is a marker, and
including a constant would add nothing to detect.

### Payload types

| Code | Meaning |
|---|---|
| `0x01` | UTF-8 JSON control message (§2) |
| `0x02` | Raw PCM, one chunk of a voice capture — **16 kHz**, mono, 16-bit |
| `0x03` | One slice of a firmware image, app → device only |

**An unrecognised type is not an error.** A reader that does not know a code must surface the frame
with its raw type byte rather than dropping it, so a peer running ahead reads as a version mismatch
someone can act on instead of as a link that connects and then goes quiet.

### CRC

CRC-16/CCITT-FALSE: polynomial `0x1021`, init `0xFFFF`, no input or output reflection, no final
XOR.

Naming the polynomial is not enough — several 16-bit CRCs share `0x1021` and differ only in init or
reflection. Both implementations assert the published check value:

```
CRC16("123456789") == 0x29B1
```

If a port of this fails only that assertion, it has the wrong variant, not a wrong loop.

### Why the length is capped

8192 is a bound on damage, not a capacity target — the largest real payload is a PCM chunk of about
1.3 KB. A corrupted length field can claim up to 65535 bytes, and with no ceiling the reader sits
waiting for a frame that will never arrive while real frames queue up behind it. That is a hang,
not a dropped message, and it is much harder to diagnose.

### Reading the stream, and why it must resync

This link cannot assume it starts at a frame boundary. The ESP32 ROM and the second-stage
bootloader both print to this port before the firmware owns it, so **every boot puts arbitrary text
in front of the first real frame.** A reader that cannot walk through that is a reader that never
starts.

The algorithm, normatively:

1. Find the first complete `A5 5A` in the buffer.
   - None: discard everything except a trailing `A5`, which may be the first half of a magic split
     across two reads. Wait for more.
   - Found, but not at offset 0: discard everything before it.
2. Fewer than 6 bytes buffered: wait for more.
3. Read `length`. **If it exceeds 8192, discard one byte and go to 1.** Those two bytes were noise
   that happened to look like a header.
4. Fewer than `6 + length + 2` bytes buffered: wait for more.
5. Check the CRC. **On mismatch, count one corrupt frame, discard one byte, and go to 1.**
6. Emit the frame and consume `6 + length + 2` bytes. Go to 1 — one read can complete several
   frames.

Two details that matter:

- Step 3 and step 5 discard **one byte, not the whole candidate frame.** The magic may have been a
  coincidence inside noise, and a genuine frame can begin one byte further in. Dropping the whole
  span would swallow it.
- A fixed-size reader (the C side uses a static buffer, because a failed allocation mid-session on
  a microcontroller is worse than 8 KB of BSS) must drop its oldest byte when full rather than
  refusing the new one. Refusing wedges the link permanently.

### Counters

Both implementations expose:

| Counter | Reads as |
|---|---|
| `discardedBytes` | bytes thrown away hunting for a boundary |
| `corruptFrames` | frames whose CRC did not check out |
| `unknownFrames` (app side) | frames with a type this build has no case for |

These exist because the *rate* is the diagnosis. A handful of discarded bytes at startup is the
bootloader's parting words and is expected. A steady trickle during a session means the two sides
disagree about the format, or the cable is bad. Without a count those look identical.

Frame bytes are **not** counted as discarded. Counting them would make a healthy link read as full
of noise.

---

## 2. Messages

Type `0x01` payloads are UTF-8 JSON objects with a `"t"` discriminator. Vocabulary is grid-app's:
a **project** is the working unit with a workspace, a **chat** is one conversation inside it, and an
**agent** is the runtime that answers.

**A TILE IS A CHAT.** Every message below keys on `chatId`. It keyed on a project until 2026-08-18, and
the change is not a rename: a project holds many chats and — since the app let every chat in a project
answer at once — one tile per project had to elect a chat to speak for the rest, so of two live turns in
one folder the panel drew one and the other did not exist. The tile carries `project` as a subtitle, so
the folder is still on screen; it is no longer what the tile *is*.

Unknown keys must be ignored. A missing key falls back to a zero value rather than failing the
whole message — a peer with an extra field is not a broken peer.

### Device → app

| `t` | Fields | Meaning |
|---|---|---|
| `hello` | `fw` string, `proto` int, `mac` string | First thing after the port opens. `mac` is also the device's USB serial number, so the app can tell one panel from another before a byte is exchanged. |
| `pong` | — | The answer to a `ping`. Empty: the arrival is the content, and it is the only thing that tells the app its port handle still reaches a running panel (below). |
| `chats.list` | — | Send me the tiles. |
| `focus` | `chatId` | The carousel settled on this tile. A statement about where the user is LOOKING, not a request to run anything — the window opens that chat so the two screens are one desk. Debounced on the device (~400 ms): a fast swipe crosses several tiles, and sending each would drag the window through every conversation on the way past. A `chatId` the app no longer has is ignored in silence; nobody is waiting on an answer to a look. |
| `turn.send` | `chatId`, `text` | The user asked for something. The chat must already exist — a tile is one, so there is nothing to create. |
| `turn.stop` | `chatId` | Interrupt that chat's turn, and only that one. The id travels because the panel can stop a chat the desktop does not have open. |
| `answer` | `chatId`, `id`, `optionId` | The user answered a `question`. `id` is echoed back verbatim — it is the app's, opaque here. |

### App → device

| `t` | Fields |
|---|---|
| `welcome` | `proto` int, `app` string, `machine: {id, name}`, `voiceLang` |
| `chats` | `items[]` of the tile shape below |
| `chat.updated` | `item` — one tile |
| `turn.started` | `chatId` |
| `turn.parts` | `chatId`, `parts[]`, `todos[]` — the turn so far as one ordered timeline (below) |
| `turn.summarizing` | `chatId` — the work is over, the headline is being written (below) |
| `turn.done` | `chatId`, `recap` — ≤15 words, and the end of the turn |
| `turn.error` | `chatId`, `message` |
| `summary` | `chatId`, `text` — ≤120 words, the body behind the headline (below) |
| `question` | `chatId`, `id`, `summary`, `command?`, `options[]` (below) |
| `question.cancel` | `chatId`, `id` |
| `ping` | — the heartbeat (below) |

#### `turn.parts`

```json
{ "t": "turn.parts", "chatId": "c-1",
  "parts": [
    { "k": "t", "text": "Reading the config" },
    { "k": "s", "label": "grep -n foo lib/", "status": "running",
      "tool": "Bash", "arg": "grep -n foo lib/", "kind": "command",
      "parent": "toolu_01ab", "t0": 4200 } ],
  "todos": [ { "text": "Find the retry loop", "status": "done" },
             { "text": "Write the guard", "status": "running" } ] }
```

`k` is `"t"` for a passage the agent wrote and `"s"` for a step it ran. **The order is the
message.** An agent says a sentence, runs a command, reads the result, says the next sentence;
sending steps as separate events would make the panel reassemble that sequence itself and get it
wrong the first time one was dropped or arrived late.

**`status` is one of exactly four values**, and the fourth is the one that bites:

| | |
|---|---|
| `running` | in flight |
| `done` | finished |
| `failed` | finished badly |
| `unknown` | **the turn ended without this step ever reporting** |

`unknown` is what a step settles to when Stop is pressed mid-command, or the agent's process dies,
or the stream breaks. A reader that treats an unrecognised status as `running` leaves a spinner
turning forever on a turn that ended — so **treat anything you do not recognise as finished, never
as running.**

**Caps.** The sender bounds this message, because §1 says an over-long frame is *refused* rather
than truncated. Today the app sends at most **12 parts**, each clipped to **200 characters**, and
then drops oldest-first until the encoded frame fits 8192 bytes — a character cap is an average,
not a bound, since 200 characters of CJK is three times the bytes of 200 characters of English. A
reader should not assume the list is complete: it is the tail of the turn, which is what a live
tile wants anyway.

Sent **whole on every change, not as a delta** — the app's `AgentRun` is replaced wholesale
upstream and a step mutates in place as it finishes, so there is no append-only stream underneath
to mirror.

#### What a step carries

| Key | Present on | Meaning |
|---|---|---|
| `label` | every part | the prose (`k:"t"`), or the step's one line (`k:"s"`) |
| `status` | steps only | the four values above |
| `tool` | steps, when known | the tool's own name — drawn in its own colour, on line 1 |
| `arg` | steps, when known | the raw argument, line 2, wrapping to three lines then ellipsis. Clipped to the same 200 characters as `label` |
| `kind` | steps | one of `command` · `web` · `tool` · `thinking`. **This is what picks the colour** — the device must not infer a colour from the tool's name |
| `parent` | steps, when nested | the id of the step that spawned this one. A step with a `parent` is a sub-agent's work and is drawn on the sub-agent band, not the main one |
| `t0` | steps | **milliseconds from the start of this turn to the moment this step started.** See below |

The step's *result* still stays behind: the app holds it for the transcript, and a 466px tile has
nowhere to draw it.

**`t0` is a fixed number, and that is the whole point.** The obvious design — send the elapsed
seconds — changes the payload every second, which defeats the sender's "say nothing when nothing
changed" rule (§ *Turn messages are unsolicited*) and puts ~3 KB on the wire every tick for a number
the device could have counted itself. So the app sends **when the step started, relative to
`turn.started`**, which does not change while the step runs. The device knows when `turn.started`
arrived, so it can render a live clock off a payload that is standing still.

> The device must **not** timestamp a step when it first sees it. `onAttach` re-sends the whole
> timeline after a panel reboot, and every step would read as having just begun.

**`todos[]` rides the message, not the parts** — it is the state of a plan, not a point in the
story. Each entry is `{text, status}`. Absent means the agent has no plan, which is different from an
empty plan and is drawn as nothing at all.

> ⚠️ **A todo's `status` is its own three-value vocabulary, NOT a step's**, and the default runs the
> other way:
>
> | | |
> |---|---|
> | `pending` | not started |
> | `running` | the item the agent is on |
> | `done` | finished |
>
> **An unrecognised todo status is drawn as `pending`, never as done.** This is the exact opposite of
> the step rule above, and the reason is that the two failure modes are opposite. An unrecognised
> *step* left spinning claims work is happening that isn't — so unknown settles to finished. An
> unrecognised *todo* drawn as finished puts a tick against work nobody has begun — so unknown
> settles to not-started. Sharing one word between the two would make one of them wrong; a plan has
> no equivalent of "ran, but never reported back".

### The tile shape

```json
{ "id": "c-1", "name": "Retry the webhook", "project": "grid-app", "agent": "claude", "model": "auto",
  "busy": true, "recap": "Retry guard shipped; all 42 tests pass", "recapKind": "done",
  "summary": "I added an idempotency key before dispatch, so a timeout no longer replays the charge." }
```

`id` is the CHAT's id and `name` its title; `project` is the folder's NAME, drawn under the title — an id
would be useless here, the panel has no project list to look one up in. `project` is absent for a chat
outside every project, and such chats **are not sent at all** today: the panel has never listed them, and
a tile with no subtitle is the one row on the carousel that cannot say where its work would land.

**Ordering is the app's sidebar order**, reused rather than re-invented: project by project in the order
the app lists them, and inside each the order the rail draws (pinned first, then most recently talked in).
Three surfaces answering "which chats matter, and in what order" differently is a bug nobody reports.

**`recap` and `summary` are the SAME PAIR the live turn sends** (below), remembered per chat so a panel
that has just been plugged in has both to draw. Sending only `recap` is what makes the tile and the reader
show one string on every cold start — they are two zones, and one sentence in both reads as a bug in the
reader. `summary` is absent until a model has written one, and the reader then says there is nothing more
rather than repeating the headline.

Deliberately thin. The panel draws a title, a folder, a state and one line of recap; a chat in the app
also has a whole transcript, and its project has instructions, memory and a workspace path — none of
that belongs on a tile. `agent`, `model`,
`recap` and `recapKind` are omitted rather than sent as null when absent.

`recapKind` tints the recap card — `done` · `failed` · `stopped`. It exists because a recap is one
line of ordinary prose whether the turn succeeded or died, and the tile has no other room to say
which. An unrecognised value must be drawn as `done`, never as an error: guessing "failed" on a
turn that worked is the worse of the two mistakes.

> `stopped` is **inferred, not recorded** — the app keeps no flag for "the user pressed stop", so it
> is read back out of the settled transcript (a step left unaccounted for). A turn stopped *before it
> ran anything* leaves no trace and arrives as `done`. Treat `stopped` as a hint worth tinting, not
> as a fact worth asserting in words.

**`agent` names the engine mark** the tile draws (`claude` · `codex` · `hermes`). It is the agent that
**answered this chat**, read off the last reply's stamp — not the one the project is configured with.
Under Auto the grid picks per turn, so the two genuinely differ, and the tile should say who spoke. A
chat nothing has answered yet falls back to the project's pick. An agent id this build has no mark for is
drawn with no mark rather than a placeholder — the row still reads.

### Turn messages are unsolicited

`turn.*` is **not** a reply to `turn.send`. The app pushes turn state for every turn in every
chat it has told the panel about — including turns started at the desktop keyboard, which the
panel never asked for and is simply reporting. A reader that only expects them after its own
`turn.send` will sit idle through most of what the machine actually does.

Two consequences worth handling rather than discovering:

- `turn.done` or `turn.error` can arrive for a project the panel does not think is running — after
  a panel reboot mid-turn, for instance. Treat it as "that project is idle now", not as an error.
- `turn.done.recap` may be the empty string: a turn can be stopped before the assistant says
  anything. Unlike the project shape, where an absent field is omitted, this key is always present.

**So are the tiles.** `projects` and `project.updated` arrive unasked too, whenever the desktop's
own list moves — a project created, renamed, deleted, or its recap changed. `projects.list` exists
for the panel to ask once on waking; a panel that only ever draws what it asked for will show a
stale board for as long as it stays plugged in.

The app is expected to **say nothing when nothing the panel can draw has changed**. That is what
keeps a link idle during a long turn, and it is why the heartbeat below has to exist.

### How a turn that worked actually ends

Not with `turn.done`. A finished turn is read at two distances, so it is written at two lengths **by
one model call** — and the tile keeps working until that call answers:

```
turn.parts …                          the agent is working
turn.summarizing                      the agent stopped; the headline is being written
turn.done      { recap }              ≤15 words — the headline, and the end of the turn
summary        { text }               ≤120 words — the body, for the reader
```

| | | |
|---|---|---|
| `recap` | **≤ 15 words** | the headline, on `turn.done`. What the tile draws, **in full** — a headline that is itself clipped has failed at the one job it has |
| `text` | **≤ 120 words** | the body, on `summary`. **Optional**: a one-line turn earns a headline and nothing more, and inventing a body from it would be inventing |

**One call, not two.** They are the same judgement at two lengths; asked separately they could disagree
about what the turn was even about. The model is given the user's own request as well as the
assistant's reply, so the headline **answers the question** instead of describing the topic — asked a
price, it leads with the price.

> **Why the tile keeps working instead of showing something at once.** The obvious design sends
> `turn.done` the moment the agent stops, carrying whatever cheap recap is to hand, and swaps in the
> real headline seconds later. Tried, and it is worse: the intermediate state is not *missing*
> information, it is **wrong** information — a sentence someone reads from across the room and then
> watches change. `turn.summarizing` says "the work is over, the account of it is coming", and the
> tile stays exactly as it was.

**`turn.summarizing` repeats, every ~5 s, until the turn is closed.** The device clears a busy tile
after **25 s** with no message (`ui_prune_stale_busy`), and a real model can spend longer than that on
one prompt — so the window is held open by saying so again, not by hoping the write is quick.

> ⚠️ **Do not bound the write under 25 s instead.** That was tried: a 20 s deadline with no beat, on
> the theory that answering before the sweep is simpler than out-running it. The grid's own model
> answered in a little over a minute, so the deadline fired on **every** turn, the tile settled on the
> cheap recap — the exact state this design exists to avoid — and the real headline arrived afterwards
> to be thrown away. Measured 2026-08-17.

The writer gives up after **90 s** and closes the turn with the cheap recap. What that number bounds is
not the device's patience — the beat covers that — but how long someone watches a finished turn claim
it is still reading.

**A turn that FAILED does not go through this.** `turn.error` is sent immediately and is already
terminal: the failure message *is* the outcome, there is nothing a model could add, and "Summarizing…"
over a turn that already broke would delay the one thing worth saying. It is never followed by a
`turn.done` — that would be a second ending for one turn.

So the order is always `turn.done` first, `summary` maybe. A summary may never arrive — no model
reachable, the call failed, the turn said nothing worth summarising — and the detail screen must read
as "nothing more to show" rather than as loading forever. It may also arrive for a project whose tile
has since moved on; it is keyed by `chatId` and describes **the turn that just ended**, so a
reader should overwrite rather than append.

A `summary` can follow **`turn.error` as well as `turn.done`** — a turn that failed halfway may still
have said enough to be worth reading. Key it to the project, not to the outcome.

### Questions

An agent can stop mid-turn and ask permission — to run a command, to write a file. The panel is a
place the user is already looking at, so it gets the question too.

```json
{ "t": "question", "chatId": "c-1", "id": "q-7",
  "summary": "Delete the build folder",
  "command": "rm -rf build",
  "options": [ { "id": "allow_once", "label": "Allow" },
               { "id": "refuse",     "label": "Deny" } ] }
```

- **`id` is opaque.** It is the app's handle for the request; echo it back in `answer` unchanged.
- **`options` is the set of answers the app can actually deliver** — **1, 2 or 3** of them. Draw what
  arrives; never invent one, never assume two, never hardcode the labels. It is deliberately *not*
  every option the agent offered: the widest grant an agent knows how to ask for is one the app
  refuses to hand out, and a button whose only possible outcome is a refusal is worse than no button.
- **`question.cancel` can arrive at any time**, and *will*: the desktop shows the same question, and
  whichever surface answers first cancels the other. It also fires when the app's own timer gives up
  (55 s today; the agent stops waiting at 60). A panel that ignores it holds a dead card forever.
- **The cancel is sent to the panel that answered, too.** Do not special-case your own answer — clear
  the card on `question.cancel` whatever caused it, and the two paths stay one path.
- An `answer` for an `id` the app has already settled is **discarded silently**, not an error — the
  two surfaces race by design.

> Only some agents ask. Two of the four run with permission checks disabled and will never send a
> `question` at all; a panel that never sees one is not necessarily broken.

### Heartbeat, and how the panel knows the app is gone

Over a cable there is no connection to lose: the app quitting looks exactly like the app having
nothing to say. Both are silence. So the app sends `ping` on a fixed cadence — **every 5 seconds**
— for as long as it is alive, and the panel reads a gap as absence:

| | |
|---|---|
| App sends `ping` | every 5 s, regardless of activity |
| Panel answers with `pong` | every one, immediately |
| Panel declares the app gone | after **15 s** with no message of any kind |
| App declares the handle dead | after **20 s** with no bytes of any kind — then closes the port and reopens it |
| Panel while it thinks the app is gone | re-sends `hello` periodically — the app may start later, and it cannot see the panel until the panel speaks |

Any inbound message counts as a sign of life, not only `ping`/`pong` — a busy link needs no extra proof.
The two windows differ (15 s / 20 s) so a single late message cannot trip both at once and have each side
conclude the other left.

**Why the app needs `pong` at all**, given the panel is the one with a screen to change: because on the
host there is no other symptom. Measured on macOS on 2026-08-17, immediately after a firmware update the
app itself had just delivered — an ESP32-S3 that reboots comes back on a `/dev/cu.usbmodem*` node with
**the same name, the same inode and the same device numbers**. Writes to the old handle keep succeeding,
the read stream never completes, and nothing raises. The app went on pinging a dead file for as long as
anyone watched, while the panel two feet away re-introduced itself every 15 s to nobody; only restarting
the app or replugging the cable recovered it. Everything else the panel sends is something a person did,
so an idle panel is silent and there is no other traffic to time out on. The update path is exactly where
this bites, which makes `pong` a requirement of shipping firmware over the cable rather than a nicety.

**`voiceLang` is a PROPOSAL; the device decides.** The app reads the machine's own locale and sends it on
`welcome` — the right default and a poor decision, because the person holding the panel may well speak
something other than the laptop is set to. So the Settings page's Voice row can change it, the choice is
kept in the device's own NVS, and **`voice.begin` carries the answer as `lang`** on every capture.

Once the row has been tapped the app's proposal is ignored, which matters because `welcome` arrives every
15 seconds on the keepalive: without that rule the tap would be undone over and over and the row would
look like a switch that springs back.

The app falls back to its own reading only when `voice.begin` carries no `lang` — a firmware old enough
not to send one, not a disagreement. **Getting this wrong does not degrade a transcript, it empties it**:
the transcriber is asked for a language the audio is not in and answers with nothing.

**`hello` repeats, and it is not a new panel each time.** The device has no port-open event to wait
on, so it keeps greeting on a cadence — fast (~2 s) while it believes nobody is there, slow (15 s)
once a session is up. The slow one is load-bearing rather than noise: if the app restarts *within*
the silence window, the panel never notices it left — the new instance's `ping` refreshes the same
timer — so without a periodic greeting the panel would hold stale tiles forever, connected to an app
that has never sent it a `welcome`.

That puts one obligation on the app, and it is easy to get wrong:

> **Answer every `hello`. Re-attach only for a panel you have not already greeted.** Attaching means
> "this device knows nothing" — it clears what the sender believes the panel has been told and pushes
> the whole turn, question and tile state again. Doing that on every greeting re-sends everything
> every 15 seconds and quietly undoes the "say nothing when nothing changed" rule that keeps the link
> idle. Compare the `mac`: a repeat from the same board is a keepalive, a different one (or the first
> after the app started) is a session.
>
> Measured on hardware 2026-08-17 — a connected panel greeted the app four times a minute, and each
> greeting re-sent the full state.

> This is also what makes it safe for a firmware to prune a tile that has gone quiet. Without a
> heartbeat, "no news for 30 seconds" and "one command that takes 30 seconds" are the same
> observation, and a panel that guesses will clear a tile whose turn is still running.

### Voice

The panel captures, the app transcribes. The device holds no cloud credential and never talks to
one: the app hands the audio to `grid stt transcribe`, which authenticates with the session token
the CLI already has.

| Direction | `t` | Fields |
|---|---|---|
| → app | `voice.begin` | `chatId` — **optional**, absent when the user spoke from a screen that names no chat (the Overview) · `cmd` — **optional**, `"goal"` or `"loop"` · `lang` — `"en"` or `"vi"` |
| → app | *(frames `0x02`)* | 16 kHz mono 16-bit PCM, in order |
| → app | `voice.end` | — |
| → device | `voice.transcript` | `routeId`, `text`, `chatId?`, `needsConfirm` |
| → device | `voice.error` | `message` — a sentence a person can act on |
| → app | `voice.confirm` | `routeId`, `chatId` |

**Routing is the hard half, not transcription.** When `voice.begin` names a project the transcript
goes there — nothing to decide. When it does not (the Overview names none), the app has to work it out,
and a wrong answer dispatches someone's sentence into the wrong repository.

It is decided by a **model**, not by "the chat talked in most recently":

```
transcript + [ { id, "<title> — <project>", last 3 headlines } … ]  →  { chatId, confidence, reason }
```

- **The title carries most of the signal** — a chat is named after what it is about — and **what it
  recently did breaks the ties** titles leave ("Fix login" and "Fix login again"). That is why the app
  keeps each chat's last **three** headlines (`~/.grid/app/panel_recaps.json`): one turn is a skewed
  picture, and a chat whose last turn was "fixed a typo" would read as a typo chat.
- **The list is CUT to the twenty most recent**, and the prompt says so. One tile per chat means a
  machine can have a hundred, and a hundred-line prompt is both a bill and a worse decision — long lists
  are where a model starts matching on surface words. The front of the tile order is "talked in most
  recently", which is where a spoken sentence belongs nearly every time.
- **There is no "none" and no declining.** The sentence has already been said and transcribed; "I
  couldn't tell" leaves the user with nothing to do but say it again. A bad fit comes back as the
  closest chat with a low confidence, which is something the app can act on.
- **`confidence` decides whether anyone is asked.** At **0.85+** the app dispatches and sends
  `needsConfirm: false`. Below it — and for every failure, including an unreachable router — it falls
  back to its own guess and sends `needsConfirm: true`.

A panel that ignores `needsConfirm` and dispatches anyway defeats the only guard there is.

⚠️ **The firmware in this repo does exactly that today.** `ui_voice_routed` answers `voice.confirm`
the moment it arrives, so `needsConfirm: true` costs one round trip and asks nobody. It is not a
disagreement with this spec — it is unwritten UI, flagged at the call site as `TODO(BE)`. Two
consequences to hold on to while it stands: routing accuracy is **entirely** the router's, and the
router's deadline is therefore a correctness knob rather than a comfort one. It was 12s until
2026-08-17, when a routing call over the hosted relay returned a correct answer in 12s, one second
late, and a question about crypto prices opened a turn in a sports project instead. It is 30s now.

> ⚠️ **Today's firmware auto-confirms.** `ui_voice_routed` focuses the guessed project and sends
> `voice.confirm` itself, with no prompt — so in practice a low-confidence pick still dispatches, and
> the user finds out where their sentence went *after* it went. The app half is built to be asked;
> making the device actually ask is a UI that does not exist yet, and the `question` card is the shape
> to reuse for it.

**`cmd` is a prefix, not a mode.** The panel's action bar has three pills — Voice, Goal, Loop — and
the two modifiers say what *kind* of thing the sentence is. They arrive as `cmd` and the app puts
`/goal ` or `/loop ` in front of the transcript before sending it as an ordinary turn. Absent means
none: a plain turn and a modified one differ by the key being there, not by its value, so a panel
that has never heard of a modifier simply omits it.

> ⚠️ **The grid CLI has no `/goal` or `/loop`** — searched across `lib/` on 2026-08-16 and neither
> string appears anywhere. A turn started from those two pills therefore most likely reaches the
> agent with a literal `/goal ` in front of it, read as words. The pills come from the reference
> device's design and were kept deliberately; this note records what pressing one actually does today
> so the next person does not have to find out by pressing it. **The panel's job ends at `cmd`** —
> what the prefix comes to mean is the app's business, and it can change without reflashing anything.

**The cap is 600 seconds — ten minutes**, and the device must draw the same number the app enforces. The
app stops accepting audio at 600 s of PCM (`kPanelVoiceMaxBytes`) and closes a capture it has heard
nothing more about at 660 s (`kPanelVoiceOpenLimit`) — the second is a backstop for a `voice.end` that
never arrived, not a second cap. A device that offers longer than the app accepts lets someone talk into
a recording that ended without saying so, which is the one failure a voice UI cannot recover from.

> **This said 60 seconds until 2026-08-18, and the reason was a bug rather than a decision.** The panel's
> record buffer was linear rather than a ring: `s_sent` counted what had gone out but never reclaimed the
> space, so capture died at 2 MB = 65 s and 60 was a number tucked underneath it. That limit then got
> explained upward — this paragraph used to justify it in terms of what a voice UI can recover from, and
> the firmware carried the same sentence. The argument was sound; the premise was a defect. Recorded here
> so nobody restores 60 believing it was ever chosen.
>
> The panel streams while it records, so the ring only has to hold the **sender's backlog** — which is
> what makes ten minutes possible on a board with 8 MB of PSRAM against a 19.2 MB recording.

**Three numbers on this path are one sum, and they live in three repositories with nothing between them
that checks:**

| | | |
|---|---|---|
| `--timeout` on `grid stt transcribe` | **120 s** | `stt_client.dart` passes it explicitly; the CLI's own default is 30 s and was written for a clip of a few seconds |
| `kPanelRouteDeadline` | **30 s** | how long a model gets to pick the project |
| `REPLY_WAIT_MS` (panel) | **180 s ceiling** | how long the panel keeps saying it is waiting. Sized to the clip — 20 s plus 0.3 s per second of audio — so a two-second press does not hold the screen for three minutes; the ceiling is what a ten-minute clip gets, and it **must exceed 120 + 30** |

`VOICE_ROUTE_WAIT_MS` (180 s) covers the same wait for the "Sending…" overlay. Change one, read all four.
This was already wrong once: the router's deadline went 12 s → 30 s on 2026-08-17 and put the worst case
at ~34 s against a 30 s wait, so the panel could report *"No answer from the computer"* seconds before
the answer landed and the turn started anyway.

⚠️ **The upper bound is the server, not the panel.** The control plane refuses a clip over **25 MiB**
(`MAX_AUDIO_BYTES`, `autonomous-grid-be/grid_networks/transcription.py`), and the invariant is:

```
seconds × sample-rate × 2  <  25 MiB
```

At 16 kHz that is a ceiling of ~13.6 minutes, and ten minutes spends 19.2 MB of it. **Raising the sample
rate without lowering the cap returns HTTP 413 to somebody who has just spoken for ten minutes** — the
worst possible moment to discover a limit. `test/panel/panel_voice_test.dart` asserts it.

### Firmware update

The app carries the image its own build was compiled with, so the two halves cannot drift: if
`hello` reports a version other than the bundled one, the app offers to fix it over the cable it is
already talking on.

| Direction | `t` | Fields |
|---|---|---|
| → device | `fw.offer` | `version`, `size`, `sha256` |
| → app | `fw.accept` | — |
| → device | *(frames `0x03`)* | the image, in order, from offset 0 |
| → app | `fw.progress` | `written` — bytes in flash so far |
| → app | `fw.done` | — the image verified; the panel reboots into it |
| → app | `fw.error` | `message` |

**Nothing is sent until `fw.accept`.** The panel decides when it is willing — an update must never
begin in the middle of a turn the user is watching. Declining is simply not answering; the app
offers again on the next `hello`.

The device verifies `sha256` over what it actually wrote, not over what it thinks it received, and
keeps running the old image if it does not match. Two OTA slots exist for exactly this
(`partitions.csv`), so a failed update costs a reboot and nothing else.

> ⚠️ **The app wins, in BOTH directions — including backwards.** "Other than the bundled one" is a
> comparison, not an ordering: a panel reporting a version the app does not carry gets the app's
> version, older or newer. That is what keeps the two halves from drifting, and it is also a trap
> with a cable in it.
>
> **What it costs you.** `idf.py flash` a new build, then let an app whose bundle predates it see the
> panel, and the panel is quietly flashed back to the old image within seconds. Measured on
> 2026-08-16: the panel was flashed to 0.1.2, and a Grid.app bundle built two days earlier offered
> 0.1.1 and took it back — twice, before anyone noticed. Nothing looks broken; the panel just shows
> the previous UI, and `idf.py flash` said `Done`.
>
> **Why it is not visible.** The `.bin` the app OFFERS is the one inside its built bundle
> (`build/macos/.../flutter_assets/assets/panel/`), not the one in the source tree. Copying a fresh
> image into `assets/panel/` changes what the NEXT app build carries and nothing at all about the app
> already running.
>
> **So, in order, every time:** copy the image in → rebuild the app → flash the device → start the
> app. Or simply don't run the app while flashing by cable. The log line to check is
> `This build carries panel firmware <v>` — if that is not the version you just built, stop.

An offer that **fails** is not offered again for the rest of the app's session. Accepting one makes
the panel erase a flash slot *before* it answers, so retrying on every `hello` would spend erase
cycles on the user's hardware every fifteen seconds — and nothing about the next `hello` changes what
went wrong. Unplugging or restarting the app is a deliberate act and gets a fresh attempt.

#### Flow control — three numbers that are one decision

`fw.progress` is **not only a progress bar. It is the ACK that opens the app's credit window**, and
it goes out **once per slice**. The app keeps at most **16 KB** unacknowledged; the panel's receive
ring holds **32 KB**.

| Number | Where | Value |
|---|---|---|
| Credit window | `kPanelFirmwareWindowBytes`, `panel_firmware_updater.dart` | 16 KB |
| Ack cadence | `PROGRESS_EVERY`, `fw_update.c` | 1 slice (8192 B) |
| Receive ring | `USJ_RX_BUF`, `panel_link.c` | 32 KB |

**Changing any one of them alone reintroduces a bug that fails silently and at the far end.** The
constraint is hardware, not taste: the ESP32-S3 USB Serial/JTAG peripheral has *no back-pressure*.
Its ISR drains the hardware FIFO unconditionally and pushes into the ring without checking whether
the push succeeded (`esp_driver_usb_serial_jtag/src/usb_serial_jtag.c`), so bytes that do not fit are
dropped there and neither side is told — no NAK, no short write, no error. Sending faster than the
panel reads does not slow the app down, it shreds the stream. The panel's reader task is also the
task that writes flash, so it is blocked for ~16 ms per slice with nothing draining the port; the
window must fit in the ring with room to spare for that.

This is measured, not reasoned. The first transfer against a real panel — 128 KB window, ack every
64 KB — wrote **0 of 1342160 bytes**: the app pushed its whole window before the first ack was due,
almost none of it survived, and both 30-second watchdogs fired at a transfer that had never started.

### Handshake

The panel sends `hello` with the protocol version it speaks. The app answers `welcome` with its
own. A mismatch is a **state to display, not an error to swallow** — the app carries the firmware
image and can offer to reflash over the same cable.

---

## 3. Test vectors

`test/vectors/panel_frame.txt` — eight frames, tab-separated:

```
name <TAB> type <TAB> payload-hex <TAB> frame-hex
```

Both implementations assert against this file. It is generated by
`scripts/gen_panel_vectors.py`, **a third implementation written from this document** rather than
transcribed from either side — so a shared misreading surfaces as a disagreement instead of being
blessed by both halves. The generator asserts the CRC check value before emitting anything.

The set covers the cases that break naive readers: an empty payload, a payload containing the magic
bytes, a real-sized PCM chunk (1280 bytes = 40 ms at the 16 kHz of §1), and a maximum-length
payload.

That choice has already paid: the vectors caught three bugs, **all three in the test harnesses
rather than in the codecs** — including one where `strtok` collapsed a run of tabs and made the
empty-payload vector disappear from the run entirely. It passed by not being there.

Regenerating (only when the format itself changes):

```bash
python3 scripts/gen_panel_vectors.py    # writes relative to itself; re-run must produce a byte-identical file
```

### Running both halves

Both are run from the app repo root:

```bash
device/esp32-circle/scripts/test_frame.sh   # C, on the host — no ESP-IDF, no flash cycle
flutter test test/panel/                    # Dart codec + message layer
```

Behaviour the vectors cannot express is covered in both suites directly: boot noise before the
first frame, a frame arriving one byte per read, two frames in one read, a corrupt frame followed
by a good one, a corrupt length not stalling the link, a magic split across two reads, and reset
dropping a half-frame.

---

## 4. Transports

The message layer must not know which transport carries it. Today there is one:

**USB CDC**, on the board's **native** USB port (`303a:1001`) — the ESP32-S3's own USB-Serial-JTAG
peripheral, *not* a UART bridge. On a board that exposes both, the bridge carries the console:
opening that one gives a link that connects, stays connected, and only ever delivers log text, which
reads as a device that never speaks rather than as the wrong port. Match on the USB id and nothing
else — never on the port's name, and never on "the only one there".

The current device is a **Waveshare ESP32-S3-Touch-AMOLED-1.75**: 466×466 round CO5300 over QSPI,
CST9217 touch, 8 MB PSRAM, 16 MB flash (dual OTA), ES8311 codec with microphone and speaker.

`tool/panel_tap.dart` in the app repo opens a real port, runs every byte through the real decoder
and prints frames plus counters. It needs no Flutter and no app build, which is why the Dart
framing and message layers import neither.
