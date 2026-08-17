// Self-update over the cable: `fw.offer` → `fw.accept` → the image in 0x03 frames → verify → reboot.
//
// The whole point of this file is in docs/overview.md: firmware and app ship from one repo, the app
// carries the .bin its own build was compiled with, and so the two halves cannot drift. There is no
// bucket, no manifest, no rollout, no upload pipeline and no internet — grid-app already has the bytes
// and is already talking on the cable it would send them over.
//
// What was taken from the reference (autonomous-code/apps/esp32-circle/main/ota.c) is the half that
// is about flash rather than about the network: write into the inactive slot, verify a SHA-256, set the
// boot partition only after it checks out, and cancel the rollback once the new image proves it runs.
// Its HTTP source, its retry ladder, its pending-OTA NVS flag and its dedicated OTA boot mode are all
// answers to "the download is slow and might die", which is not a question a USB cable asks.
//
// ONE THING IS DELIBERATELY DIFFERENT from the reference, and it is the verification. That firmware
// stages the whole image in PSRAM and hashes the STAGED COPY before writing it. This one hashes the
// bytes READ BACK OUT OF THE PARTITION after esp_ota_end — i.e. what actually landed in flash. It costs
// a pass over ~2.5 MB of flash and it closes the gap the staged check leaves open: an image that was
// received perfectly and written badly passes the first test and fails the second.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// If this boot is a freshly installed image still on probation, confirm it. Call once at boot, after the
// display and the link are up — see the note in fw_update.c for what "proves it runs" means here.
void fw_mark_valid(void);

// grid-app is offering an image. The panel decides, and a `no` is silence: docs/panel-protocol.md §2 says
// declining is simply not answering, and the app offers again on the next `hello`.
void fw_on_offer(const char *version, int size, const char *sha256);

// One 0x03 frame. Frames arrive in order from offset 0 and are written as they land.
void fw_on_slice(const uint8_t *data, size_t len);

// True between `fw.accept` and the reboot. The link layer uses it to keep an offer from arriving on top
// of a transfer already running.
bool fw_in_progress(void);

// Give up on a transfer that has stopped arriving. Called from the handshake task's existing loop,
// because this file has no task of its own and the failure it catches is real: a grid-app that accepts,
// sends part of an image and then stops — crashed, or interrupted by its user — leaves an unplugged
// cable's failure path untriggered, the port still open, and the panel showing a progress bar forever.
void fw_tick(void);

// The session ended with an update in flight. Aborts it and leaves the old image running — which it
// still is, since the boot partition is only ever switched at the very end.
void fw_abort(const char *why);
