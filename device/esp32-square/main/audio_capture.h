// Microphone capture: I2S RX + ES7210 ADC (esp_codec_dev) → mono 16-bit PCM.
//
// Lifted from autonomous-code/apps/esp32-square-s3/main/audio_capture.c, which runs on this exact
// board. ONE edit on the way in: THE SAMPLE RATE IS 16 kHz, not the reference's 8 kHz. See below.
//
// The speaker half comes across untouched. An earlier pass here dropped it, reasoning that this panel
// sits on the desk of the computer whose screen already has the answer. That was a change to a file
// that had been paid for on this board, made for a reason nobody had measured — and ui_screens.c calls
// audio_notify_done() from six places, so dropping it meant editing the screens too. Both edits are
// gone now: the beep costs a 4 KiB task and a pre-rendered tone, and the alternative was rewriting
// working code to save it.
//
// ⚠️ THE I2S PIN ROLES ARE UNVERIFIED AND FAIL AS SILENCE. board_pins.h names GPIO5 as MCLK and GPIO16
// as SCLK, which is the reverse of the ordering on Waveshare's other boards, and nobody has yet recorded
// a sample on this one. A wrong role here does not return an error from any call in this file: every
// esp_codec_dev entry point reports ESP_OK and the mic delivers zeros forever. Before debugging anything
// else in the voice path, record one second and check the RMS is non-zero (docs/hardware.md).
#pragma once

#include <stdbool.h>
#include <stdint.h>

// 16 kHz, where the reference records 8 kHz — a product decision, not a tuning one.
//
// The panel has to hear Vietnamese. Its tones are carried largely by where the energy sits above ~3 kHz,
// and 8 kHz sampling puts the Nyquist limit at 4 kHz — it throws that band away before any transcriber
// sees it. The reference could afford 8 kHz because its constraint was a flaky WiFi uplink where halving
// the bytes halved the failures; this device sends over a USB cable at 32 KB/s against hundreds of KB/s
// of headroom, so the trade it was making does not exist here.
//
// THE CONSEQUENCE, stated because it is easy to inherit the old number by reading the old comment: the
// 2 MB PSRAM record buffer in voice.c holds ~131 s of audio at 8 kHz and ~65 s at 16 kHz. Every duration
// derived from a byte count halves with this constant, and so does the chunk count behind the speech
// gate — see VOICE_GATE_MIN_MS in voice.c, which is why that one is written as a duration.
//
// docs/protocol.md §1 fixes this in the wire format as well: type 0x02 is "16 kHz, mono, 16-bit". This
// constant and that line have to agree, and there is no field in the frame that would carry a
// disagreement — a rate mismatch arrives as speech at the wrong speed, not as an error.
#define AUDIO_SAMPLE_RATE 16000

// One-time init of I2S RX/TX + the ES7210. Returns false if the mic is not usable, which leaves the rest
// of the firmware running: a panel that cannot hear is still a panel that shows projects.
bool audio_capture_init(void);

// Open the mic stream before reading. Returns true on success.
bool audio_capture_start(void);

// Blocking read of exactly `len` PCM bytes into `buf`. Returns `len`, or <= 0 on error.
int audio_capture_read(uint8_t *buf, int len);

// Close the mic stream. The I2S channels and the codec stay initialised for the next utterance.
void audio_capture_stop(void);

// --- Notification beep (ES8311 speaker output) ---
// One-time init of the ES8311 OUT path + a worker task that plays a short tone on request.
// Call once at boot (after the I2C bus is up). Safe no-op if the speaker codec isn't present.
void audio_notify_init(void);

// Play a short "beep beep" (non-blocking; queues to the beep task). Debounced ~1s.
// Safe to call from any task (e.g. the link task on a turn-done event).
void audio_notify_done(void);
