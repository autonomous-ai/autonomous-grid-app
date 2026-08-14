# Grid Panel — the board

Waveshare **ESP32-S3-Touch-LCD-4B** ("Smart 86 Box"): ESP32-S3R8, 16 MB flash, 8 MB PSRAM, a
480×480 IPS panel and a capacitive touch layer.

This page separates two kinds of claim, because mixing them is how people lose days:

- **Measured** — checked against the physical board on 2026-08-13/14. Commands included so you can
  repeat it.
- **Inherited** — learned from the reference firmware in
  `autonomous-code/apps/esp32-square-s3`, which runs on this same board. Believable, and written
  down by people who paid for the knowledge, but not re-verified here.

---

## Measured

### There are two USB ports, and they are not interchangeable

| Port | Chip | USB ID | Carries |
|---|---|---|---|
| 1 | WCH **CH343** UART bridge | `1a86:55d3` | the console |
| 2 | Espressif **USB-Serial-JTAG**, native in the SoC | `303a:1001` | the protocol |

Both enumerate at once and can be plugged in together. On macOS they appear as
`/dev/cu.usbmodem*` — port 1 named after its serial number, port 2 after its USB location id.

```bash
system_profiler SPUSBDataType | grep -A6 -E "0x303a|0x1a86"
ls /dev/cu.usbmodem*
```

**Use port 2 for the protocol.** It is USB CDC, so it has no baud ceiling — unlike port 1, which is
a UART bridge and is limited by whatever rate the two ends agree on. Naming the wrong port gives
you a link that opens fine and then only ever delivers log text, which reads exactly like a peer
that is not talking.

### The console is duplicated onto both ports

Measured: reading both ports simultaneously for 20 s while touching the screen returned **373
bytes, byte-identical on both**.

```
I (191684) commander: ota status: error
I (193233) app: refresh agents start gen=1
I (193682) app: projects: 1
I (193686) ram: RAM tag=machine_refresh int_free=131051 ... stack_free_min=1392B
```

The cause is visible in the reference firmware's `sdkconfig`: console goes to UART0
(`CONFIG_ESP_CONSOLE_UART_DEFAULT=y`) **and** `CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y`
mirrors it to the native port.

**This firmware turns it off**, in `sdkconfig.defaults`. Left on, every log line lands in the
middle of the protocol stream and the reader spends its life resyncing.

⚠️ **And the obvious way to turn it off does nothing.** `CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG`
is one arm of a Kconfig **choice**, and a defaults file cannot *deselect* an arm — writing `…=n`
is silently ignored and you get a build that looks configured and still mirrors the console. The
fix is to select the other arm:

```
CONFIG_ESP_CONSOLE_UART_DEFAULT=y
CONFIG_ESP_CONSOLE_SECONDARY_NONE=y
```

Verify in the *generated* `sdkconfig`, never in the defaults file — it should read
`# CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG is not set`.

A residue remains and is by design: the ROM and second-stage bootloader print before the app can
disable anything, so **port 2 still carries some text at every boot.** The framing handles it — see
[`protocol.md`](protocol.md) §1 — but a reader that cannot resync will never start.

### The USB serial number is the MAC

Port 2 reports `Serial Number: A4:CB:8F:CF:D0:78`, which is the device's MAC.

This makes identification nearly free: filter the USB tree for `303a:1001` and read the serial
number, and the app knows *which* panel is attached before exchanging a byte. No device id to
invent, no handshake needed to answer "is this the same panel as last time".

### The bring-up chain works, first flash

Measured 2026-08-14: this firmware was flashed and **the panel lit and drew its screen**. That one
observation confirms the whole inherited chain below at once — the I2C → TCA9554 → panel reset →
RGB order, the expander constants being used as bitmasks, the ST7701 taking its init over the
bit-banged 3-wire SPI, and the backlight being **active-low with no hardware PWM**. Each of those
fails silently and independently, so a lit screen is the only cheap proof that none of them did.

The boot also confirmed the console split. Reading the native port right after reset returned
**64 bytes and then nothing**:

```
I (101) esp_image: segment 0: paddr=00020020 vaddr=3c080020 size
```

That is the second-stage bootloader printing before the app can disable anything — the residue
described above — followed by silence once the app owns the port. Which is exactly what
`CONFIG_ESP_CONSOLE_SECONDARY_NONE=y` is supposed to buy, and it is now observed rather than
assumed.

Still unverified after this flash: **touch orientation** (`swap_xy` / `mirror_x` / `mirror_y` are
deliberately neutral until someone drags a finger across the real glass) and the I2S pin roles.

### Headroom

From the telemetry line above, on the reference firmware with everything running:

| | Free |
|---|---|
| Internal RAM | ~128 KB (worst-case low-water ~117 KB) |
| PSRAM | ~2.6 MB — *after* the 2 MB voice buffer is reserved |
| LVGL pool | ~462 KB of 525 KB, 1% fragmentation |

Comfortable. The protocol's transport costs about **16.4 KB of internal RAM** — the decoder's
8.2 KB buffer plus a send buffer of the same size, since a frame is encoded whole before it
goes out.

Also visible in that line: `stack_free_min=1392B` on the refresh task, which matches the reference
firmware's own comment about measuring 1,332 B free at a 6 KiB stack and raising it to 7 KiB. Their
notes describe the board they actually have.

---

## Inherited — the four things that bite

All four are documented in the reference firmware. They are here because each one fails in a way
that does not look like its cause.

### 1. Bring-up order is not negotiable: I2C → TCA9554 → panel reset → RGB

The ST7701's initialisation registers **do not travel on the 16 data lines.** They go over a 3-wire
SPI bit-banged on a TCA9554 I/O expander. Skip a step and the panel stays dark with nothing logged
as wrong.

This board also puts behind that expander what its siblings have on real GPIOs: the panel's SPI,
the panel reset, and the speaker amplifier enable.

### 2. The expander constants are bitmasks, not pin numbers

`esp_io_expander`'s API takes `(1 << n)` values. Writing the plain pin number compiles, runs,
returns `ESP_OK`, and **drives the wrong pin**: `0` addresses nothing, `1` addresses pin 0, `2`
addresses pin 1.

That is not hypothetical — it cost the reference firmware's authors a day of a black panel while
every API call reported success. The tell is the TCA9554's own config register (`0x03`) reading
`0x5C`, i.e. a line still configured as an input.

There is also a pin Waveshare's own BSP omits and their Arduino demo drives: the panel enable on
expander pin 7. Left floating — which is how a TCA9554 powers up — the panel initialises without
error and shows nothing.

### 3. The backlight comment contradicts the code, and the code is right

`main/board/board_pins.h` describes GPIO4 as *"real backlight PWM (LEDC), ACTIVE-HIGH"* and points
at `ui/display.c` for detail. That file reaches the **opposite** conclusion, with three recorded
measurements:

1. Toggling the pad blinks the panel, so it is the backlight.
2. Held high with a white frame in the buffer, the panel is black — so **high is off**.
3. LEDC at 5 kHz produced no light at any duty in either polarity — so the pad **gates a boost
   converter rather than modulating one**. There is no hardware dimming.

`display.c` defines `BL_ON_LEVEL 0` and falls back to a black overlay for perceived brightness.
**Trust the code; fix the comment when lifting the file.** The reference README repeats the wrong
half too, and presents PWM as this board's difference from its sibling when in practice the two now
behave the same.

### 4. The I2S pin roles are genuinely unverified, and fail silently

The BSP names GPIO5 as MCLK and GPIO16 as SCLK, which is the reverse of the ordering on Waveshare's
other boards, and the sibling P4 board hit exactly this class of contradiction between its wiki and
its BSP.

**The failure mode is silence, not an error.** Before debugging capture code, record one second of
PCM and check the RMS is non-zero. Everything else about the audio path can look correct while the
microphone delivers nothing.

---

## Other inherited notes worth keeping

- **`CONFIG_SPIRAM_XIP_FROM_PSRAM` is load-bearing, not an optimisation.** The panel scans its
  frame buffer out of PSRAM continuously. In bounce-buffer mode the LCD cannot run while the
  external cache is off — during an NVS write or a flash install — and XIP is what keeps the cache
  live across flash writes. It is why this board can show a progress bar while flashing itself.
- **Take pins from the BSP, not the wiki.** The wiki page for this board is contaminated with an
  AMOLED sibling's content — it describes a CO5300 panel over QSPI and a CST9217 touch controller,
  none of which exist here, and carries no GPIO table at all. Source of truth is
  `bsp/esp32_s3_touch_lcd_4b` in Waveshare's components repo.
- **Touch is polled.** GT911 at `0x5D`, with INT and RST unconnected on this board, so the driver
  must be built with `int_gpio_num = GPIO_NUM_NC`. There is no interrupt to wait on.
- **Flash layout already supports self-update.** `partitions.csv` carries dual OTA slots
  (`ota_0`/`ota_1`, ~7.9 MB each) against a current image of 2.46 MB, and the reference `ota.c`
  stages a whole image into PSRAM before writing flash. Reflashing over USB therefore only has to
  replace the *source of the bytes* — the staging, SHA-256 verification, slot switch and
  rollback-cancel logic already exist and are reusable as they stand.
- **The reference's comments carry round-board leftovers in more than one file**, so read them
  against the code rather than trusting them. Found so far: `partitions.csv`'s header names the
  wrong board; `board_i2c.h` documents `SDA=15 / SCL=14` and a `CST9217` touch controller, when
  this board is `47 / 48` and GT911; and the backlight note above. Each was corrected on the way
  in — but the pattern is the point, and the next file lifted deserves the same suspicion.
