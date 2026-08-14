// The USB transport under panel_frame: bytes in from the native USB port, frames out to it.
//
// This is the whole of the device's connection to the outside world. There is no WiFi on this firmware
// and there is not going to be — plugging the cable in is the authorization, and dropping the network
// took provisioning, pairing, a LAN server and a reconnect ladder out of the design with it
// (docs/overview.md). So everything the panel ever says goes through the two functions below.
//
// ── WHICH PORT ──────────────────────────────────────────────────────────────────────────────────────
// The board exposes TWO USB ports and they are not interchangeable:
//
//   port 1  WCH CH343 UART bridge        1a86:55d3   the console
//   port 2  USB-Serial-JTAG, in the SoC  303a:1001   THIS — the protocol
//
// Port 2 is what the ESP32-S3's own USB peripheral presents, which is why this file uses IDF's
// usb_serial_jtag driver and no TinyUSB: there is nothing to compose, the CDC interface already exists.
// Getting the two backwards on the app side gives a link that opens fine and then only ever delivers log
// text — which reads exactly like a peer that is not talking. See docs/hardware.md.
//
// ── THE CONSOLE MUST NOT BE ON THIS PORT ────────────────────────────────────────────────────────────
// Measured on the real board: with CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG on, 20 s of console
// output arrived byte-for-byte identical on BOTH ports — i.e. every log line was being injected into the
// middle of the protocol stream. sdkconfig.defaults turns it off (CONFIG_ESP_CONSOLE_SECONDARY_NONE=y)
// and that line is load-bearing, not tidiness. It costs nothing: the console still goes to port 1.
//
// A residue survives and is by design — the ROM and the second-stage bootloader print here before the
// app owns the port, so port 2 carries some text at every boot. The framing is built to walk through it.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "panel_frame.h"

// Install the USB-Serial-JTAG driver and start the reader task.
//
// `cb` is invoked once per decoded frame, ON THE READER TASK, with the payload pointing into the
// decoder's own buffer — it is only valid for the duration of the call. Anything that must outlive it
// gets copied by the callback. Anything that touches LVGL takes display_lock() first.
//
// Returns false if the driver would not install, which leaves the panel running with no link rather than
// failing to boot: a device that shows "Not connected" is diagnosable from across the room, and a device
// stuck in a boot loop is not.
bool panel_link_start(panel_frame_cb cb, void *ctx);

// Frame `payload` and write it to the port. Returns true when the whole frame went out.
//
// A false return means the host is not draining the port (an unopened or unplugged CDC endpoint fills
// the FIFO and the write times out). That is a normal state for this device, not an error condition —
// the panel sits unplugged or in front of a machine with grid-app closed for most of its life. Callers
// should treat it as "not connected", never retry in a tight loop.
//
// If a write is cut short mid-frame the peer sees a truncated frame, which its decoder resyncs past on
// the next magic — that recovery is exactly what the CRC-plus-magic-scan exists for, so a bad moment
// costs one message rather than the link.
bool panel_link_send(uint8_t type, const uint8_t *payload, size_t payload_len);

// Framing health. The RATE is the diagnosis, not the totals: a handful of discarded bytes right after
// boot is the bootloader's parting words and is expected, while a steady trickle during a session means
// the two sides disagree about the format or the cable is bad. Without a count those look identical.
void panel_link_counters(uint32_t *corrupt_frames, uint32_t *discarded_bytes);

// Drop any half-received frame. For the layer above to call when it decides a session has ended and a
// new one begun — leftover bytes belong to the old one, and carrying them across puts a stale
// half-frame in front of the first real frame of the new session.
//
// This layer cannot make that call itself. usb_serial_jtag_is_connected() reports whether a USB HOST is
// present, which is not the same question as whether grid-app has the port open, and this device spends
// most of its life plugged into a machine that is not running the app.
//
// Call it FROM THE FRAME CALLBACK. The decoder has one reader — the link task — and no lock; resetting
// it from another task while that task is mid-feed corrupts the very buffer meant to be cleared.
void panel_link_reset_decoder(void);
