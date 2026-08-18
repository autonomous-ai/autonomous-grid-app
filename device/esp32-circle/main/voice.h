// One voice turn: press, capture, stream, and wait for what the computer heard.
//
// The panel captures and the app transcribes (docs/panel-protocol.md §2, "Voice"). This device holds no cloud
// credential and never talks to one — grid-app hands the audio to `grid stt transcribe`, which
// authenticates with the session token the CLI already has. Losing the panel therefore loses nothing.
//
// ── WHAT WAS TAKEN FROM THE REFERENCE, AND WHAT WAS LEFT THERE ──────────────────────────────────────
// autonomous-code/apps/esp32-circle/main/audio_client.c does this job over a TLS websocket on flaky
// WiFi. Two of its parts are worth having anywhere: the PSRAM record buffer, which decouples the
// microphone from the sender so a slow write cannot overrun the I2S DMA and eat live speech, and the
// SPEECH GATE, which stops a stray press from starting a turn.
//
// Everything else in that file exists because a TLS socket over WiFi drops in the middle of an
// utterance: `voice_resume`, `resume_ack`, `stream_recover_step`, a ring view of the buffer holding the
// last ~131 s so the missing tail can be re-sent, a 60 s outage budget, per-write stall backoff. None of
// it was copied. A USB cable does not drop mid-utterance — and when it DOES go (unplugged, or the
// machine sleeps) there is no peer left to resume with, so the honest answer is to abandon the turn and
// say so, not to buffer against a reconnection that is not coming.
#pragma once

#include <stdbool.h>

// Reserve the PSRAM record buffer. Call once at boot, from app_main.
//
// Early and up front rather than on the first press: this is a 2 MB CONTIGUOUS block, and a contiguous
// block that size is much harder to obtain once the rest of the firmware has been allocating for a
// while. Failing here costs a log line at boot; failing at the press costs the utterance the user just
// spoke.
void voice_init(void);

// Which slash command, if any, this utterance carries. The panel picks it from the action bar's Goal or
// Loop pill; `voice.begin` sends it as `cmd` and grid-app prepends "/goal " or "/loop " to whatever it
// heard (docs/panel-protocol.md §2).
typedef enum { VOICE_CMD_NONE = 0, VOICE_CMD_GOAL, VOICE_CMD_LOOP } voice_cmd_t;

// Start capturing. `project_id` is the tile on screen, or NULL/"" from a screen that names no project —
// `voice.begin` then omits the field and grid-app has to route the transcript itself.
//
// Returns with the capture task running; nothing is sent yet. See the speech gate in voice.c for why
// `voice.begin` does not go out until the microphone has actually heard something.
void voice_start(const char *project_id, voice_cmd_t cmd);

// Stop capturing and finish the turn. Non-blocking: the capture task drains what is left, sends
// `voice.end` and then waits for the transcript on its own.
void voice_stop(void);

// Throw the utterance away without sending it. For a capture the UI decides should never have started —
// a press that caught no speech, or a project deleted mid-sentence. No `voice.end` goes out, so grid-app
// has nothing to transcribe and the turn simply never happened.
void voice_abort(void);

// True from the press until the turn is finished — including the wait for `voice.transcript`, which is
// still part of the turn as far as the screen and the firmware-update guard are concerned.
bool voice_active(void);

// True only while the microphone is still open. False once the last chunk is out and the panel is
// waiting on the transcript — which is when the screen swaps its waveform for the sending indicator.
bool voice_recording(void);

// True once this capture has crossed the speech gate. The UI's silence watchdog discards a recording
// that never does (an accidental press, or a forgotten one).
bool voice_heard(void);

// grid-app answered (`voice.transcript` or `voice.error`), so the wait is over. Called by panel_client.
void voice_reply_seen(void);

// The link died with a turn in flight. Abandons it: the audio has nowhere to go and the screen must not
// keep claiming the panel is listening.
void voice_link_lost(void);
