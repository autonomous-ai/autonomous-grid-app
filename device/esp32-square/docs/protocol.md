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
| `0x02` | Raw PCM, one chunk of a voice capture — 8 kHz, mono, 16-bit |

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
| `turn.step` | `projectId`, `label`, `status` |
| `turn.done` | `projectId`, `recap` |
| `turn.error` | `projectId`, `message` |

### The project shape

```json
{ "id": "p-1", "name": "grid-app", "agent": "claude",
  "model": "auto", "busy": true, "recap": "Ran the tests" }
```

Deliberately thin. The panel draws a name, a state and one line of recap; a project in the app also
has instructions, memory and a workspace path, and none of that belongs on a tile. `agent`, `model`
and `recap` are omitted rather than sent as null when absent.

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
bytes, a real-sized PCM chunk (1280 bytes = 80 ms), and a maximum-length payload.

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
