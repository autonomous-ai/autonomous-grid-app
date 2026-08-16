#include "voice.h"

#include <stdio.h>
#include <string.h>

#include "audio_capture.h"
#include "display.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "panel_client.h"
#include "ram_telemetry.h"
#include "ui_screens.h"

static const char *TAG = "voice";

// One PCM frame's worth of audio. 1280 bytes is the size docs/protocol.md §3 builds a test vector
// around, so keeping it makes the vector a real-sized chunk rather than a made-up one.
//
// ⚠️ It is 40 ms at this firmware's 16 kHz, where the same 1280 bytes was 80 ms at the reference's
// 8 kHz. Nothing on the wire carries a duration — the frame is bytes and a rate agreed in the protocol
// — so this only matters where a chunk COUNT is standing in for a time. There is exactly one such place
// and it is the speech gate below, which is why that one is written as milliseconds.
#define CHUNK      1280
#define CHUNK_MS   ((CHUNK / 2) * 1000 / AUDIO_SAMPLE_RATE)

// The record buffer. 2 MB, the reference's number, and PSRAM because internal RAM is the scarce one here
// (the framing layer alone already spends ~16 KB of it).
//
// ⚠️ 2 MB holds ~131 s at the reference's 8 kHz and ~65 s at this firmware's 16 kHz. That halving is the
// price of hearing Vietnamese properly (see AUDIO_SAMPLE_RATE) and it is worth stating rather than
// leaving the reader to divide: one minute of speech is the cap, which is far past anything a person
// says to a desk panel in one press.
//
// WHY BUFFER AT ALL when the link is a cable that never drops? Because the microphone must not wait for
// the sender. The I2S DMA is shallow; a write that blocks for the host's 100 ms timeout while the mic
// keeps producing overruns it and the dropped samples are live speech. Capture appends here at a fixed
// 32 KB/s and the sender drains behind it, so a slow moment on the port costs latency instead of words.
#define BUF_MAX     (2 * 1024 * 1024)
#define BUF_SECONDS (BUF_MAX / (AUDIO_SAMPLE_RATE * 2))

// THE SPEECH GATE. A cheap energy check, and the one thing standing between a pocket brush against the
// panel and a turn dispatched into a real repository.
//
// Each chunk's mean |sample| is compared to a threshold, and the gate latches once enough of the chunks
// in a recent window are loud — MOST of the window, not all of it, and NOT a consecutive run.
//
// The consecutive version was wrong, and wrong in a way that got worse when the sample rate doubled.
// Speech is not continuously loud: stops and the gaps between syllables put whole chunks under any
// useful threshold. At 8 kHz a chunk was 80 ms and a syllable gap usually fell inside one; at 16 kHz a
// chunk is 40 ms, so the same speech now lands a quiet chunk in the middle of the run far more often —
// and a single one reset the counter to zero. Same 320 ms requirement, twice the chances to fail it. A
// gate that needs 320 ms of UNBROKEN loudness is asking for a shout, not a sentence.
//
// A window keeps what the run was actually for. The mic's spiky silence floor (which peaks around 350)
// and the one-off knock of a fingertip landing on the glass still cannot accumulate into "heard",
// because they cannot keep most of a third of a second above the threshold.
//
// The reference expresses the requirement as 4 chunks and means ~320 ms. Written as a count it would
// have silently become 160 ms here the moment the sample rate doubled — the number would still have
// looked right and the gate would have been half as strict. It is a DURATION; the count is derived.
#define VOICE_GATE_MEANABS    600
#define VOICE_GATE_MIN_MS     320
#define VOICE_GATE_MIN_CHUNKS (VOICE_GATE_MIN_MS / CHUNK_MS)
// Twice the requirement, so "most of the window" is the test. Capped at 32 because the window is a bit
// per chunk in one uint32_t.
#define VOICE_GATE_WINDOW     (VOICE_GATE_MIN_CHUNKS * 2)

// How long the panel waits for grid-app to answer `voice.end` before it stops claiming to be listening.
//
// There is no reply timeout in the protocol and there should not be one — this is a screen deciding how
// long to keep a promise, not a message layer deciding a peer is dead. Transcription of a minute of
// audio on a desktop is seconds; 30 s is long enough that a slow machine still lands, and short enough
// that a person is not left looking at "Transcribing…" wondering whether to press it again.
#define REPLY_WAIT_MS 30000

// The capture task's stack. INTERNAL RAM, which is what a plain xTaskCreate gives on this IDF, and the
// reference records why that matters: a flash write disables the cache, PSRAM is unreadable while it is
// off, and a task running from a PSRAM stack loses its own stack mid-call. Its P4 sibling crashed
// exactly there. CONFIG_SPIRAM_XIP_FROM_PSRAM (on here, for the RGB panel's sake) very likely defuses
// it — but "very likely" against a crash that costs the utterance someone just spoke, for 6 KB, is not
// a trade worth taking.
#define VOICE_STACK 6144

static EXT_RAM_BSS_ATTR char s_project[ID_MAX];
static voice_cmd_t s_cmd;           // the Goal/Loop modifier this utterance carries, if any

static uint8_t *s_buf;
static size_t   s_len;        // PCM bytes captured this utterance
static size_t   s_sent;       // PCM bytes handed to the link

// volatile: written on the UI/link tasks and read on the capture task. A stale read costs one loop
// period, which is 40 ms, and a mutex around a bool that only ever goes one way would buy nothing.
static volatile bool s_active;
static volatile bool s_stop_req;
static volatile bool s_abandon;     // the link went away; there is nobody to send the rest to
static volatile bool s_reply_seen;

static bool s_heard;                // the gate has latched for this utterance
static uint32_t s_gate_window;      // one bit per recent chunk, 1 = above the threshold
static int      s_gate_chunks;      // chunks fed since this utterance began

// The loudest and the average chunk level this utterance, kept ONLY so the panel can say what it
// measured when it heard nothing.
//
// Without it "Nothing heard" is unfalsifiable from the outside: a microphone wired wrong delivers
// zeros while every codec call still returns ESP_OK, and that looks exactly like a threshold set too
// high, which looks exactly like someone speaking too quietly. One number separates all three, and it
// costs two integers. The board's I2S pin roles are unverified (board_pins.h) and fail as SILENCE, so
// this is the difference between a five-minute answer and an afternoon.
static uint32_t s_lvl_peak;
static uint64_t s_lvl_sum;

// Feed one just-captured chunk to the gate. No-op once speech is confirmed — the check costs a pass over
// 640 samples and buys nothing after that.
static void gate_feed(const uint8_t *buf, int n)
{
    if (n < 2) return;
    const int16_t *s = (const int16_t *)buf;
    const int ns = n / 2;
    uint32_t sumabs = 0;
    for (int i = 0; i < ns; i++) { int v = s[i]; sumabs += (uint32_t)(v < 0 ? -v : v); }
    const uint32_t mean = sumabs / (uint32_t)ns;

    // Measured on every chunk, including after the gate latches — the level is what this utterance
    // actually sounded like, not what the first third of a second sounded like.
    if (mean > s_lvl_peak) s_lvl_peak = mean;
    s_lvl_sum += mean;
    s_gate_chunks++;

    if (s_heard) return;

    // Shift the window along and score it. Most of the window loud, rather than all of it in a row.
    s_gate_window = (s_gate_window << 1) | (mean > VOICE_GATE_MEANABS ? 1u : 0u);
    if (VOICE_GATE_WINDOW < 32) s_gate_window &= (1u << VOICE_GATE_WINDOW) - 1u;
    if (__builtin_popcount(s_gate_window) >= VOICE_GATE_MIN_CHUNKS) s_heard = true;
}

// Hand captured-but-unsent audio to the link, in protocol-sized chunks. Returns false when the host
// stopped reading, which on this device means the session is over — see voice.h for why there is no
// retry ladder behind that.
//
// BOUNDED per call while capture is running (`max_chunks` < 0 means "everything", which is only right
// once the microphone is closed). A send can park for the link's write timeout, and an unbounded
// catch-up inside one capture iteration is time the mic is not being read — the I2S DMA is shallow and
// what it drops is live speech. The reference firmware records exactly this bug and bounds its own
// flush for the same reason; more than one chunk per turn still means the backlog shrinks.
#define DRAIN_CHUNKS_PER_TURN 6

static bool drain(int max_chunks)
{
    for (int done = 0; s_sent < s_len; done++) {
        if (max_chunks >= 0 && done >= max_chunks) break;
        size_t n = s_len - s_sent;
        if (n > CHUNK) n = CHUNK;
        if (!panel_client_send_pcm(s_buf + s_sent, n)) return false;
        s_sent += n;
    }
    return true;
}

// NOTHING here pushes a voice state into the UI, where an earlier version of this file pushed four.
// The screens own their own indicator — ui_voice_start/stop drive it, and it POLLS voice_active() and
// voice_recording() for the rest. One owner: two halves both setting the same icon is how an indicator
// ends up stuck on a screen after the thing it indicates has finished.

static void notice(const char *title, const char *body)
{
    display_lock();
    ui_show_notice(title, body);
    display_unlock();
}

static void voice_task(void *arg)
{
    (void)arg;
    uint8_t tmp[CHUNK];
    const int64_t t0 = esp_timer_get_time();

    s_len = s_sent = 0;
    s_heard = false;
    s_gate_window = 0;
    s_gate_chunks = 0;
    s_lvl_peak = 0;
    s_lvl_sum = 0;
    bool begun = false;      // `voice.begin` has gone out
    bool lost  = false;      // a send failed; the rest of this turn has nowhere to go

    if (!audio_capture_start()) {
        // Honest about which half failed. "Voice unavailable" would leave the reader guessing between a
        // missing microphone and a missing computer, and only one of those is fixable from the desk.
        ESP_LOGE(TAG, "mic would not start — no capture");
        notice("The microphone did not start",
               "The panel could not open its microphone. Unplug it and plug it back in.");
        s_active = false;
        vTaskDelete(NULL);
        return;
    }
    ram_telemetry_checkpoint("voice_start");

    while (!s_stop_req && !s_abandon) {
        int n = audio_capture_read(tmp, CHUNK);
        if (n <= 0) { vTaskDelay(pdMS_TO_TICKS(5)); continue; }

        if (s_buf && s_len + (size_t)n <= BUF_MAX) {
            memcpy(s_buf + s_len, tmp, (size_t)n);
            s_len += (size_t)n;
        } else {
            // Out of room, or there was never any room. Either way stop and send what there is rather
            // than silently recording over the start of the sentence.
            ESP_LOGW(TAG, "record buffer full at %us — stopping", (unsigned)BUF_SECONDS);
            break;
        }
        gate_feed(tmp, n);

        // NOTHING GOES OUT UNTIL THE GATE LATCHES, and that is what makes the gate worth having.
        //
        // Streaming from the first chunk and deciding afterwards would mean a stray press had already
        // sent `voice.begin`, already put an utterance in front of grid-app, and could only be undone by
        // a message the protocol does not have. Holding the first ~320 ms in the buffer costs that much
        // latency once per turn and keeps every byte — including the attack of the first word, which is
        // exactly what a gate that dropped its warm-up would eat.
        if (!begun && s_heard) {
            panel_client_voice_begin(s_project, s_cmd);
            begun = true;
            ESP_LOGI(TAG, "speech heard — voice.begin%s%s", s_project[0] ? " for " : " (no project)",
                     s_project[0] ? s_project : "");
        }
        if (begun && !drain(DRAIN_CHUNKS_PER_TURN)) { lost = true; break; }

        // A voice turn produces no touch after the first one, and the idle timer would blank the panel
        // mid-sentence — on the one screen that is currently saying the panel is listening.
        display_bump_activity();
    }

    audio_capture_stop();

    const unsigned secs = (unsigned)((esp_timer_get_time() - t0) / 1000000);
    const unsigned avg = s_gate_chunks ? (unsigned)(s_lvl_sum / (uint64_t)s_gate_chunks) : 0u;
    ESP_LOGI(TAG, "capture ended: %us, %uKB, %s (level avg %u peak %u, gate %d)", secs,
             (unsigned)(s_len / 1024), s_heard ? "speech" : "no speech", avg,
             (unsigned)s_lvl_peak, VOICE_GATE_MEANABS);

    if (s_abandon || lost) {
        // The cable left, or the host stopped reading. Say so plainly instead of leaving the panel
        // looking like it is still listening: the audio is gone and nothing is coming back.
        ESP_LOGW(TAG, "voice turn abandoned — the link went away");
        notice("Lost the computer", "Nothing was sent. Check the cable and try again.");
    } else if (!begun) {
        // The gate never latched: nothing was sent, no turn was started, and this is the ONLY outcome
        // where the panel has to explain itself — from the outside a silent press and a working one look
        // identical.
        // The level goes IN THE MESSAGE, not only in a log nobody can reach.
        //
        // This panel's console is on the other USB port, and the port it talks to grid-app on is not the
        // one carrying ESP_LOG — so on a desk with one cable plugged in, a log line does not exist. A
        // number here turns "it doesn't work" into a diagnosis anyone can read off the glass and repeat
        // back: 0 is a microphone that is not delivering samples at all (suspect the I2S pin roles, which
        // board_pins.h records as unverified), a level below the gate is speech too quiet or a threshold
        // too high, and a level above it with this message showing would be a bug in the gate itself.
        char body[160];
        snprintf(body, sizeof(body),
                 "Level %u peak, %u average — the gate wants %d. "
                 "Tap the mic and speak once it turns red.",
                 (unsigned)s_lvl_peak, avg, VOICE_GATE_MEANABS);
        notice("Nothing heard", body);
    } else if (!drain(-1)) {   // the mic is closed now, so there is nothing left to interleave with
        ESP_LOGW(TAG, "the tail of the recording could not be sent");
        notice("Lost the computer", "Only part of what you said was sent. Check the cable and try again.");
    } else {
        panel_client_voice_end();
        // Wait for `voice.transcript` or `voice.error` HERE rather than letting the task end and having
        // the screen wait on its own. One state machine, one place it can be read from, and the turn is
        // not over until the panel knows what the computer heard.
        const int64_t deadline = esp_timer_get_time() + (int64_t)REPLY_WAIT_MS * 1000;
        while (!s_reply_seen && !s_abandon && esp_timer_get_time() < deadline) {
            vTaskDelay(pdMS_TO_TICKS(50));
        }
        if (!s_reply_seen) {
            notice("No answer from the computer",
                   "The panel sent what you said and heard nothing back.");
        }
    }

    s_active = false;
    ram_telemetry_checkpoint("voice_end");
    vTaskDelete(NULL);
}

void voice_init(void)
{
    if (s_buf) return;
    s_buf = ram_psram_alloc(BUF_MAX, "voice_record_buffer");
    ESP_LOGI(TAG, "record buffer %s (%d KB = %us at %d Hz) — PSRAM largest block %uKB",
             s_buf ? "reserved" : "ALLOC FAILED", BUF_MAX / 1024, (unsigned)BUF_SECONDS,
             AUDIO_SAMPLE_RATE,
             (unsigned)(heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM) / 1024));
}

void voice_start(const char *project_id, voice_cmd_t cmd)
{
    if (s_active) return;   // one utterance at a time; the second press is the user repeating themselves
    if (!s_buf) {
        // One retry, because the alternative is a voice button that silently does nothing for the rest
        // of the device's uptime.
        s_buf = ram_psram_alloc(BUF_MAX, "voice_record_buffer_retry");
        if (!s_buf) {
            ESP_LOGE(TAG, "no PSRAM record buffer — refusing to record");
            notice("The panel is out of memory", "Unplug it and plug it back in.");
            return;
        }
    }

    snprintf(s_project, sizeof(s_project), "%s", project_id ? project_id : "");
    s_cmd = cmd;
    s_stop_req = false;
    s_abandon = false;
    s_reply_seen = false;
    // Set BEFORE the task exists: a UI that reads "not active" in the gap would paint the idle mic over a
    // capture that is already running.
    s_active = true;

    if (xTaskCreate(voice_task, "voice", VOICE_STACK, NULL, 6, NULL) != pdPASS) {
        s_active = false;
        ESP_LOGE(TAG, "capture task create failed");
        notice("The panel could not start listening", "Unplug it and plug it back in.");
    }
}

void voice_stop(void)
{
    if (s_active) s_stop_req = true;
}

// Same stop, but the tail is never sent. `s_abandon` is what the capture loop already checks to mean
// "there is nobody to send this to", and a capture the UI has decided to discard is in exactly that
// position — the difference is only who decided. No `voice.end` goes out either way, so grid-app has
// nothing to transcribe and the turn simply never happened.
void voice_abort(void)
{
    if (!s_active) return;
    s_abandon = true;
    s_stop_req = true;
}

bool voice_active(void)
{
    return s_active;
}

// The microphone half of `active`. True until the capture loop leaves; false while the tail is going out
// and the panel is waiting on the transcript, which is the moment the screen swaps waveform for sparkles.
bool voice_recording(void)
{
    return s_active && !s_stop_req && !s_abandon;
}

bool voice_heard(void)
{
    return s_heard;
}

void voice_reply_seen(void)
{
    s_reply_seen = true;
}

void voice_link_lost(void)
{
    if (!s_active) return;
    s_abandon = true;
    s_stop_req = true;
}
