# Grid Panel — wire protocol

Normative. Everything here is implemented twice with no shared code — `main/panel_frame.c` on the
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
a **project** is the working unit with a workspace, an **agent** is the runtime that answers in it.

Unknown keys must be ignored. A missing key falls back to a zero value rather than failing the
whole message — a peer with an extra field is not a broken peer.

### Device → app

| `t` | Fields | Meaning |
|---|---|---|
| `hello` | `fw` string, `proto` int, `mac` string | First thing after the port opens. `mac` is also the device's USB serial number, so the app can tell one panel from another before a byte is exchanged. |
| `projects.list` | — | Send me the tiles. |
| `turn.send` | `projectId`, `text` | The user asked for something. |
| `turn.stop` | `projectId` | Interrupt that project's turn. The id travels because the panel can stop a project the desktop does not have open. |

### App → device

| `t` | Fields |
|---|---|
| `welcome` | `proto` int, `app` string, `machine: {id, name}` |
| `projects` | `items[]` of the project shape below |
| `project.updated` | `item` — one project |
| `turn.started` | `projectId` |
| `turn.parts` | `projectId`, `parts[]` — the turn so far as one ordered timeline (below) |
| `turn.done` | `projectId`, `recap` |
| `turn.error` | `projectId`, `message` |

#### `turn.parts`

```json
{ "t": "turn.parts", "projectId": "p-1", "parts": [
    { "k": "t", "text": "Reading the config" },
    { "k": "s", "label": "grep -n foo lib/", "status": "running" } ] }
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

A step carries only `label` and `status`. The app also holds each step's request and result for its
own transcript; a 480×480 tile draws a line and a spinner, and shipping the rest would spend the
frame budget on characters this screen cannot show.

### The project shape

```json
{ "id": "p-1", "name": "grid-app", "agent": "claude",
  "model": "auto", "busy": true, "recap": "Ran the tests" }
```

Deliberately thin. The panel draws a name, a state and one line of recap; a project in the app also
has instructions, memory and a workspace path, and none of that belongs on a tile. `agent`, `model`
and `recap` are omitted rather than sent as null when absent.

### Turn messages are unsolicited

`turn.*` is **not** a reply to `turn.send`. The app pushes turn state for every turn in every
project it has told the panel about — including turns started at the desktop keyboard, which the
panel never asked for and is simply reporting. A reader that only expects them after its own
`turn.send` will sit idle through most of what the machine actually does.

Two consequences worth handling rather than discovering:

- `turn.done` or `turn.error` can arrive for a project the panel does not think is running — after
  a panel reboot mid-turn, for instance. Treat it as "that project is idle now", not as an error.
- `turn.done.recap` may be the empty string: a turn can be stopped before the assistant says
  anything. Unlike the project shape, where an absent field is omitted, this key is always present.

### Voice

The panel captures, the app transcribes. The device holds no cloud credential and never talks to
one: the app hands the audio to `grid stt transcribe`, which authenticates with the session token
the CLI already has.

| Direction | `t` | Fields |
|---|---|---|
| → app | `voice.begin` | `projectId` — **optional**, absent when the user spoke from a screen that names no project · `cmd` — **optional**, `"goal"` or `"loop"` |
| → app | *(frames `0x02`)* | 16 kHz mono 16-bit PCM, in order |
| → app | `voice.end` | — |
| → device | `voice.transcript` | `routeId`, `text`, `projectId?`, `needsConfirm` |
| → device | `voice.error` | `message` — a sentence a person can act on |
| → app | `voice.confirm` | `routeId`, `projectId` |

**Routing is the hard half, not transcription.** When `voice.begin` names a project the transcript
goes there. When it does not, the app has to guess, and a guess that dispatches itself into a real
repository is worse than one extra tap — so it answers with `needsConfirm: true` and waits for
`voice.confirm`. A panel that ignores `needsConfirm` and dispatches anyway defeats the only guard
there is.

**`cmd` is a prefix, not a mode.** The panel's action bar has three pills — Voice, Goal, Loop — and
the two modifiers say what *kind* of thing the sentence is. They arrive as `cmd` and the app puts
`/goal ` or `/loop ` in front of the transcript before sending it as an ordinary turn. Absent means
none: a plain turn and a modified one differ by the key being there, not by its value, so a panel
that has never heard of a modifier simply omits it.

> ⚠️ **The grid CLI has no `/goal` or `/loop`** — searched across `lib/` on 2026-08-16 and neither
> string appears anywhere. A turn started from those two pills therefore most likely reaches the
> agent with a literal `/goal ` in front of it, read as words. The pills come from the reference
> device's design and were kept deliberately; this note records what pressing one actually does today
> so the next person does not have to find out by pressing it.

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
`scripts/gen_vectors.py`, **a third implementation written from this document** rather than
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
python3 scripts/gen_vectors.py
```

### Running both halves

```bash
./scripts/test_frame.sh                 # C, on the host — no ESP-IDF, no flash cycle
cd ../.. && flutter test test/panel/    # Dart codec + message layer
```

Behaviour the vectors cannot express is covered in both suites directly: boot noise before the
first frame, a frame arriving one byte per read, two frames in one read, a corrupt frame followed
by a good one, a corrupt length not stalling the link, a magic split across two reads, and reset
dropping a half-frame.

---

## 4. Transports

The message layer must not know which transport carries it. Today there is one:

**USB CDC**, on the board's **native** USB port (`303a:1001`), *not* the CH343 bridge — that one
carries the console. See [`hardware.md`](hardware.md); getting this backwards gives you a link that
opens and then only ever delivers log text.

`tool/panel_tap.dart` in the app repo opens a real port, runs every byte through the real decoder
and prints frames plus counters. It needs no Flutter and no app build, which is why the Dart
framing and message layers import neither.
