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
| Firmware skeleton (board, display, touch, boot flow, USB link) | 🟨 builds — **never run on hardware** |
| Firmware app (screens, message layer) | ⬜ not started |
| grid-app service (projects, turn events, stop) | ⬜ not started |
| Voice (capture → STT → dispatch) | ⬜ not started |

Nothing on the device runs this protocol yet. The board currently ships someone else's firmware;
see [`docs/overview.md`](docs/overview.md) for what that is and why it matters.

**The firmware skeleton has never been flashed.** It compiles, and that is genuinely all that is
known about it: whether the panel lights, whether touch is the right way up, and whether the native
USB port carries clean bytes are each a measurement nobody has taken. The board layer is lifted from
firmware that does run on this exact board, which makes it likely rather than verified — and every
one of those three fails silently, so "it booted" is not evidence any of them worked. `display.c`
logs the panel's real refresh rate ~2 s in; that line is the first thing to look for.

## Docs

- **[`docs/overview.md`](docs/overview.md)** — what this is, why USB rather than the network, and
  who owns which half. Start here.
- **[`docs/protocol.md`](docs/protocol.md)** — the wire format and message vocabulary, normative.
  What you need to implement either side.
- **[`docs/hardware.md`](docs/hardware.md)** — what was measured on the real board, and the four
  things that bite. Read before touching the board layer.

## Layout

```
main/          app_main.c (boot flow) · panel_frame.{c,h} (codec) · panel_link.{c,h} (USB transport)
main/board/    pins, I2C, TCA9554 expander, AXP2101 — lifted from the reference firmware
main/ui/       display (ST7701+LVGL), touch (GT911), screens, fonts, icons
scripts/       gen_vectors.py (shared test vectors) · test_frame.sh (host test)
test/          host tests + vectors/panel_frame.txt
docs/          this
```

`main/panel_frame.c` is compiled twice: into the firmware, and by `scripts/test_frame.sh` with a
plain host compiler. That is why it contains no ESP-IDF header and must not gain one — the moment it
does, the only cheap check on the wire format goes with it.

The Dart half lives in the app: `lib/infrastructure/panel/`, tested in `test/panel/`, with a manual
probe at `tool/panel_tap.dart`.

## Building the firmware

```bash
source ~/esp/esp-idf/export.sh                # ESP-IDF v5.5
idf.py set-target esp32s3 && idf.py build
idf.py -p /dev/cu.usbmodem<serial> flash monitor   # the CH343 port — the console, NOT the protocol
```

## Running the tests

Neither half needs the device, and neither needs Xcode.

```bash
./scripts/test_frame.sh                       # C codec against the shared vectors
cd ../.. && flutter test test/panel/          # Dart codec + message layer
cd ../.. && dart run tool/panel_tap.dart      # a real device, if one is plugged in
```
