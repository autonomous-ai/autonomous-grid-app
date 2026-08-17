// Microphone capture: I2S RX + ES7210 ADC (esp_codec_dev) → mono 16-bit PCM.
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Record at 16 kHz, which is what `docs/panel-protocol.md` §1 says a `0x02` frame carries.
//
// ⚠️ THE ONE EDIT IN THIS OTHERWISE VERBATIM FILE, and it has to be here rather than absorbed
// downstream. The reference recorded at 8 kHz for two reasons, and this device has neither:
//
//   * it halved the upload on flaky WiFi — a cable is not throughput-limited;
//   * it TOLD THE BACKEND the rate, via an `sr` query param. This wire has no such field. The
//     rate is fixed by the protocol instead, so a device that captures at another one has no way
//     to say so and nobody to say it to.
//
// Leaving 8 kHz here is therefore not a quality trade, it is a silent corruption: the app stamps
// 16 kHz into the WAV header it builds from these bytes, so the transcriber replays real speech
// at double speed and answers with an empty string. Measured on hardware 2026-08-17 — 4.4 s of
// clear speech came back as "I couldn't make out any words", and the app's own log called it
// 2.2 s, because it too was dividing by the rate it had been promised.
//
// The board this protocol was written against (the deleted esp32-square) recorded at 16 kHz.
#define AUDIO_SAMPLE_RATE 16000

// One-time init of I2S RX + ES7210. Returns true on success (tolerant: false → no mic).
bool audio_capture_init(void);

// Open the mic stream (16k/mono/16-bit) before reading. Returns true on success.
bool audio_capture_start(void);

// Blocking read of PCM bytes into buf (len bytes). Returns bytes read, <=0 on error.
int audio_capture_read(uint8_t *buf, int len);

// Close the mic stream.
void audio_capture_stop(void);

// --- Notification beep (ES8311 speaker output) ---
// One-time init of the ES8311 OUT path + a worker task that plays a short tone on request.
// Call once at boot (after the I2C bus is up). Safe no-op if the speaker codec isn't present.
void audio_notify_init(void);

// Play a short "beep beep" (non-blocking; queues to the beep task). Debounced ~1s.
// Safe to call from any task (e.g. the commander WS event task on a "done" event).
void audio_notify_done(void);
