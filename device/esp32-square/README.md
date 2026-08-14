# Grid Panel — `device/esp32-square`

Firmware for a 480×480 touch panel (Waveshare ESP32-S3-Touch-LCD-4B) that plugs into a computer
over USB and drives **grid-app**'s projects: see what each agent is doing, interrupt a turn, and
speak an instruction without going to the keyboard.

It lives inside the grid-app repo on purpose. Firmware and app speak a protocol that exists in two
hand-written copies with no shared code, so every change to it has to land in one commit or the two
halves drift — and drift here means a device in the field that connects and then says nothing.

## Status

| | |
|---|---|
| Framing codec (Dart + C, shared vectors) | ✅ built and tested |
| Message layer (Dart) | ✅ built and tested |
| `tool/panel_tap.dart` — drive a real device with no app build | ✅ |
| Firmware app (UI, boot flow, link client) | ⬜ not started |
| grid-app service (projects, turn events, stop) | ⬜ not started |
| Voice (capture → STT → dispatch) | ⬜ not started |

Nothing on the device runs this protocol yet. The board currently ships someone else's firmware;
see [`docs/overview.md`](docs/overview.md) for what that is and why it matters.

## Docs

- **[`docs/overview.md`](docs/overview.md)** — what this is, why USB rather than the network, and
  who owns which half. Start here.
- **[`docs/protocol.md`](docs/protocol.md)** — the wire format and message vocabulary, normative.
  What you need to implement either side.
- **[`docs/hardware.md`](docs/hardware.md)** — what was measured on the real board, and the four
  things that bite. Read before touching the board layer.

## Layout

```
main/          firmware sources — panel_frame.{c,h} is the only finished part
scripts/       gen_vectors.py (shared test vectors) · test_frame.sh (host test)
test/          host tests + vectors/panel_frame.txt
docs/          this
```

The Dart half lives in the app: `lib/infrastructure/panel/`, tested in `test/panel/`, with a manual
probe at `tool/panel_tap.dart`.

## Running the tests

Neither half needs the device, and neither needs Xcode.

```bash
./scripts/test_frame.sh                       # C codec against the shared vectors
cd ../.. && flutter test test/panel/          # Dart codec + message layer
cd ../.. && dart run tool/panel_tap.dart      # a real device, if one is plugged in
```
