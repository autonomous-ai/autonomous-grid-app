#include "panel_client.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "display.h"
#include "esp_app_desc.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"   // esp_timer_get_time() — the heartbeat clock
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "fw_update.h"
#include "panel_link.h"
#include "ui_screens.h"
#include "voice.h"
#include "audio_capture.h"   // audio_notify_done() — the beep on a finished turn

static const char *TAG = "client";

// How often `hello` goes out while there is no session.
//
// The panel CANNOT see grid-app open the port. usb_serial_jtag_is_connected() answers "is a USB host
// driving this port", which is true of any running computer with the cable in, and there is no
// port-open event below that. So the handshake is a retry, not a one-shot: say hello until someone
// answers. 2 s is fast enough that plugging in feels immediate and slow enough that a panel sitting on
// a desk with grid-app closed costs ~30 bytes a minute on a link with nothing else to do.
#define HELLO_PERIOD_MS 2000

// And how often it goes out once there IS a session.
//
// Re-sending is not a new message, a new field or a changed meaning — the app answers `welcome` and the
// session simply re-establishes. Without it, grid-app quitting and restarting with the cable still in
// would wedge the panel forever: the app's port opens with no hello to answer, and the panel waits for a
// welcome that only a hello would have triggered.
//
// 15 s rather than 2: this is a fallback for a rare event, not a poll.
#define HELLO_KEEPALIVE_MS 15000

// ── THE HEARTBEAT, AND HOW THE PANEL KNOWS THE APP IS GONE ──────────────────────────────────────────
// Over a cable there is no connection to lose. The app quitting looks exactly like the app having nothing
// to say — both are silence — so grid-app sends `ping` every 5 s for as long as it is alive and the panel
// reads a gap as absence (docs/panel-protocol.md, "Heartbeat").
//
// FIFTEEN SECONDS, three ping periods: one lost ping is a busy moment, three in a row is not.
#define SILENCE_IS_GONE_MS 15000

// ANY inbound message counts as a sign of life, not only `ping` — a busy link needs no extra proof, and a
// panel that insisted on the heartbeat specifically would declare a machine dead in the middle of the one
// turn that was flooding it with turn.parts.
static volatile int64_t s_last_rx_us;

// This is also what makes it safe to prune a tile that has gone quiet. Without a heartbeat, "no news for
// 30 seconds" and "one command that takes 30 seconds" are the same observation, and a panel that guesses
// will clear a tile whose turn is still running.
static void note_inbound(void)
{
    s_last_rx_us = esp_timer_get_time();
}

// The handshake/liveness task. It only ever builds one small JSON object and hands it to panel_link, so
// this is not the stack the message handlers run on — those run on the link's reader task.
#define HELLO_STACK 3072

// The ids from the last `projects` message, kept only long enough to reconcile removals against what the
// UI already holds.
//
// A file-scope array in PSRAM BSS rather than a local: at MAX_TILES this is several KB and the reader
// task that runs it has a 4 KB stack. It is only ever touched from that one task.
static EXT_RAM_BSS_ATTR char s_ids[MAX_TILES][ID_MAX];

// volatile: written on one task and read on another (the handshake task decides a session ended, the
// link task and the UI read the result), and not worth a mutex — a stale read costs one loop period.
static volatile bool s_connected;     // `welcome` seen, session believed live
// The last `welcome` named THIS product. Separate from s_connected because a protocol mismatch clears
// that one while the app reflashes the panel over the same cable — see on_welcome().
static volatile bool s_product_ok;
static uint32_t s_bad;
static uint32_t s_unknown;
static char     s_machine_id[64];
static char     s_machine_name[64];
static int      s_reported_mismatch;  // the app protocol already shown on screen; 0 = none

// ── JSON, leniently ─────────────────────────────────────────────────────────────────────────────────
// panel-protocol.md §2: unknown keys are ignored, and a missing key falls back to a zero value rather than
// failing the whole message. A peer with an extra field is not a broken peer. These three accessors are
// that rule, applied once, so no handler has to remember it.

static const char *jstr(const cJSON *o, const char *key)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return (cJSON_IsString(v) && v->valuestring) ? v->valuestring : "";
}

static int jint(const cJSON *o, const char *key)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsNumber(v) ? v->valueint : 0;
}

static bool jbool(const cJSON *o, const char *key)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsTrue(v);
}

// The gerunds the Working line rotates through, and the ONLY name a sub-agent row can be given: the wire
// carries `parent` (the id of the step that spawned this one) and nothing that says what the sub-agent IS.
//
// Picked from the step's own `t0`, which is a fixed number for the life of that step, so a row keeps its
// word across the many re-sends of one timeline instead of flickering a new one each time. Kept in step
// with the list in ui_screens.c — two lists that drift are two vocabularies on one screen.
static const char *GERUNDS[] = {
    "Working", "Brewing", "Cooking", "Churning", "Frosting", "Simmering", "Tinkering",
    "Conjuring", "Composing", "Percolating", "Wrangling", "Hatching", "Concocting", "Puttering",
};

static const char *panel_gerund(int t0_ms)
{
    const int n = (int)(sizeof(GERUNDS) / sizeof(GERUNDS[0]));
    int i = (t0_ms / 1000) % n;
    if (i < 0) i = -i;
    return GERUNDS[i];
}

// ── SENDING ─────────────────────────────────────────────────────────────────────────────────────────

static void session_lost(const char *why);

// Serialise `msg`, send it, and free it. Takes ownership of `msg` on every path, including failure —
// an error path that leaks is the one nobody exercises until the device has been up for a week.
static bool send_json(cJSON *msg)
{
    if (!msg) return false;
    char *text = cJSON_PrintUnformatted(msg);
    cJSON_Delete(msg);
    if (!text) {
        ESP_LOGE(TAG, "out of memory serialising a message");
        return false;
    }
    bool ok = panel_link_send(PANEL_TYPE_JSON, (const uint8_t *)text, strlen(text));
    cJSON_free(text);
    // A failed write means the host is not draining the port. That is the resting state of an unplugged
    // panel and not an error — but if we thought we had a session, we no longer do.
    if (!ok && s_connected) session_lost("the host stopped reading");
    return ok;
}

// The device's MAC, formatted the way the USB descriptor's serial number is.
//
// panel-protocol.md §2 leans on these being the same string: `mac` is "also the device's USB serial number, so
// the app can tell one panel from another before a byte is exchanged". The ESP32-S3's USB-Serial-JTAG
// serial number is built by ROM from the base (efuse factory) MAC, which is what esp_efuse_mac_get_default
// returns — so the BYTES are certainly right.
//
// ⚠️ The FORMATTING is not verified. Uppercase colon-separated is what macOS shows for this peripheral,
// but nothing in this repo checks it and the app side does not match on the serial number yet. If panel
// identification ever starts failing, compare this against `ioreg -p IOUSB -l | grep "USB Serial Number"`
// before looking anywhere else.
static void device_mac(char *out, size_t cap)
{
    uint8_t mac[6] = {0};
    if (esp_efuse_mac_get_default(mac) != ESP_OK) {
        ESP_LOGW(TAG, "could not read the MAC — hello will carry an empty one");
        if (cap) out[0] = '\0';
        return;
    }
    snprintf(out, cap, "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

const char *panel_fw_version(void)
{
    const esp_app_desc_t *d = esp_app_get_description();
    return (d && d->version[0]) ? d->version : "unknown";
}

static void send_hello(void)
{
    char mac[24];
    device_mac(mac, sizeof(mac));
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "hello");
    // WHICH PRODUCT IS GREETING. First field after the type because it is the one that decides whether
    // the rest is addressed to the reader at all — see PANEL_PRODUCT. An app that does not recognise it
    // is supposed to answer nothing and let go of the port.
    cJSON_AddStringToObject(m, "product", PANEL_PRODUCT);
    // From the image, not from a constant — see panel_fw_version(). grid-app compares this against the
    // version inside the .bin it is holding, so a second source for it is a permanent false mismatch.
    cJSON_AddStringToObject(m, "fw", panel_fw_version());
    cJSON_AddNumberToObject(m, "proto", PANEL_PROTO_VERSION);
    cJSON_AddStringToObject(m, "mac", mac);

    // THE HEALTH LINE. Internal RAM free now, and the low-water mark since boot.
    //
    // Internal specifically, not total: PSRAM is plentiful here and tells you nothing, while internal
    // DMA-capable RAM is what LVGL's draw buffers, the USB ring and every task stack compete for, and
    // running short of it does not announce itself — it degrades into allocations landing somewhere
    // slower, which the user experiences as the screen stuttering and nobody experiences as an error.
    //
    // It rides on `hello` because `hello` already goes out every 15 seconds on the one cable that is
    // always plugged in. The console is on the OTHER USB port, so on a one-cable desk ESP_LOG does not
    // exist — and a panel that can only report its health down a channel nobody is listening to cannot
    // report its health. The low-water mark is the more useful half: a transient squeeze during boot or
    // a firmware write is invisible in an instantaneous reading taken afterwards.
    cJSON_AddNumberToObject(m, "heap", (double)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    cJSON_AddNumberToObject(m, "heapmin",
                            (double)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL));

    // ⚠️ TODO(BE): NO DRAW STATS ON THIS BOARD, and their absence is a real loss rather than a tidy-up.
    // The predecessor firmware rode `fps` / `kpxs` / `cpu` on this same message, and `kpxs*1000/fps` — the
    // average area repainted per frame — is the number that diagnoses a stutter and the one no amount of
    // looking provides: a carousel that is accidentally full-screen and one that is not look identical
    // until it is divided. They came from display_draw_stats(), two counters in the flush path, and
    // ui/display.c here is a byte-for-byte copy of the reference's (the CO5300 init sequence is verbatim
    // from Waveshare and the whole point of copying it is that it is not edited). Adding them back means
    // touching that file deliberately, with a diff worth reviewing — not slipping two lines into it here.
    send_json(m);
}

// The answer to grid-app's heartbeat. Empty on purpose — the ARRIVAL is the content.
//
// grid-app has no other way to find out that the port it is holding has gone stale. Measured on macOS on
// 2026-08-17, right after this device took a firmware update over the cable: rebooting leaves the host's
// /dev/cu.usbmodem node with the same name, the same inode and the same device numbers, writes to the old
// handle keep succeeding, and its read stream never ends. The app pinged a dead file for as long as
// anyone watched while this panel sat there saying `hello` every 15 s to nobody.
//
// Cheap enough not to think about: ~30 bytes every 5 s, on a cable that carries 8 KB firmware slices.
static void send_pong(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "pong");
    send_json(m);
}

// The tile the user swiped to. Sent so the window can follow the panel — the two screens are one desk,
// and a person who spins the carousel to a chat means to look at that chat.
//
// DEBOUNCED by the caller, not here: a fast swipe crosses several tiles, and sending each one would drag
// the app's view through every conversation on the way past.
// A finger's travel on the glass, in device pixels — the panel used as a touchpad.
//
// Sent WHILE THE FINGER IS DOWN, in pieces: one stroke arrives as several of these. The caller decides
// when (touch.c: every ~8px or ~50ms), because the throttle belongs where the touch stream is, not here.
//
// Nothing is remembered on this side. The panel has no idea how tall the window's transcript is, so it
// reports movement and lets the half that owns the list do the arithmetic.
void panel_client_send_scroll(panel_scroll_phase_t phase, int dy, int velocity)
{
    static const char *const NAMES[] = { "down", "move", "up" };
    // No early-out on a zero dy any more: an empty frame is the point of the two ends of a stroke.
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "scroll");
    cJSON_AddStringToObject(m, "phase", NAMES[phase]);
    cJSON_AddNumberToObject(m, "dy", dy);
    if (phase == PANEL_SCROLL_UP) cJSON_AddNumberToObject(m, "v", velocity);
    send_json(m);
}

void panel_client_send_focus(const char *chat_id)
{
    if (!chat_id || !chat_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "focus");
    cJSON_AddStringToObject(m, "chatId", chat_id);
    ESP_LOGI(TAG, "focus → %s", chat_id);
    send_json(m);
}

static void send_projects_list(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "chats.list");
    send_json(m);
}

void panel_client_send_turn(const char *chat_id, const char *text)
{
    if (!chat_id || !chat_id[0] || !text || !text[0]) return;
    cJSON *m = cJSON_CreateObject();
    cJSON_AddStringToObject(m, "t", "turn.send");
    cJSON_AddStringToObject(m, "chatId", chat_id);
    cJSON_AddStringToObject(m, "text", text);
    send_json(m);
}

void panel_client_stop_project(const char *chat_id)
{
    if (!chat_id || !chat_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "turn.stop");
    cJSON_AddStringToObject(m, "chatId", chat_id);
    ESP_LOGI(TAG, "turn.stop %s", chat_id);
    send_json(m);
}

void panel_client_answer(const char *chat_id, const char *id, const char *option_id)
{
    if (!id || !id[0] || !option_id || !option_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "answer");
    cJSON_AddStringToObject(m, "chatId", chat_id ? chat_id : "");
    // VERBATIM, both of them. `id` is grid-app's handle for the request and `optionId` is one of the ids
    // it offered; neither means anything on this side, and anything the panel derived for itself would be
    // an answer to a question nobody asked.
    cJSON_AddStringToObject(m, "id", id);
    cJSON_AddStringToObject(m, "optionId", option_id);
    ESP_LOGI(TAG, "answer %s -> %s", id, option_id);
    send_json(m);
}

// ── VOICE, OUTBOUND ─────────────────────────────────────────────────────────────────────────────────

void panel_client_voice_begin(const char *chat_id, voice_cmd_t cmd)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "voice.begin");
    // OMITTED, not empty. panel-protocol.md §2 makes `chatId` optional and absence is the message: it tells
    // grid-app the user spoke from a screen that names no project, so it has to route the transcript
    // itself and ask. An empty string would be a project id — one that matches nothing.
    if (chat_id && chat_id[0]) cJSON_AddStringToObject(m, "chatId", chat_id);
    // Same rule for the modifier: VOICE_CMD_NONE sends no `cmd` key at all rather than "none", so a
    // plain turn and a modified one differ by a field being there, not by its value.
    if (cmd == VOICE_CMD_GOAL)      cJSON_AddStringToObject(m, "cmd", "goal");
    else if (cmd == VOICE_CMD_LOOP) cJSON_AddStringToObject(m, "cmd", "loop");
    // Which language to transcribe THIS capture in — the Settings page's Voice row, or grid-app's own
    // proposal when nobody has touched it. Sent per capture rather than announced once: it is a property
    // of what was just said, and a device whose setting changed mid-session would otherwise have to
    // remember to tell anyone.
    cJSON_AddStringToObject(m, "lang", ui_voice_lang());
    send_json(m);
}

bool panel_client_send_pcm(const uint8_t *pcm, size_t len)
{
    bool ok = panel_link_send(PANEL_TYPE_PCM, pcm, len);
    // Same reading as a failed JSON write: the host is not draining the port. Mid-utterance that means
    // the session is over, and the voice layer stops rather than filling a buffer for nobody.
    if (!ok && s_connected) session_lost("the host stopped reading during a voice turn");
    return ok;
}

void panel_client_voice_end(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "voice.end");
    send_json(m);
}

void panel_client_voice_confirm(const char *route_id, const char *chat_id)
{
    if (!route_id || !chat_id || !chat_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "voice.confirm");
    cJSON_AddStringToObject(m, "routeId", route_id);
    cJSON_AddStringToObject(m, "chatId", chat_id);
    ESP_LOGI(TAG, "voice.confirm route=%s → %s", route_id, chat_id);
    send_json(m);
}

// ── FIRMWARE UPDATE, OUTBOUND ───────────────────────────────────────────────────────────────────────

void panel_client_fw_accept(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "fw.accept");
    send_json(m);
}

void panel_client_fw_progress(uint32_t written)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "fw.progress");
    cJSON_AddNumberToObject(m, "written", (double)written);
    send_json(m);
}

void panel_client_shot_begin(const char *name, int w, int h)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "shot.begin");
    cJSON_AddStringToObject(m, "name", name ? name : "");
    cJSON_AddNumberToObject(m, "w", w);
    cJSON_AddNumberToObject(m, "h", h);
    send_json(m);
}

void panel_client_shot_row(int y, const char *b64)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "shot.row");
    cJSON_AddNumberToObject(m, "y", y);
    cJSON_AddStringToObject(m, "b64", b64 ? b64 : "");
    send_json(m);
}

void panel_client_shot_end(const char *name)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "shot.end");
    cJSON_AddStringToObject(m, "name", name ? name : "");
    send_json(m);
}

void panel_client_fw_done(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "fw.done");
    send_json(m);
}

void panel_client_fw_error(const char *message)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "fw.error");
    // "a sentence a person can act on" is what docs/panel-protocol.md asks of voice.error; the same standard is
    // worth holding here, because this string is what grid-app puts in front of whoever pressed Update.
    cJSON_AddStringToObject(m, "message", message ? message : "The update failed.");
    send_json(m);
}

// ── SESSION ─────────────────────────────────────────────────────────────────────────────────────────

static void session_lost(const char *why)
{
    // A standing version mismatch counts as something to tear down. It is not a session, but it IS a
    // screen making a claim about a machine — and once the cable is out that claim is stale in exactly
    // the way a project tile would be.
    if (!s_connected && s_reported_mismatch == 0) return;
    s_connected = false;
    // Cleared with the rest of it. The gate on `fw.offer` is only worth having if it expires: leaving it
    // armed would mean that once the user's own app had greeted, ANY app on the port could write flash
    // for as long as the board stayed up — including one that arrived after this cable came out.
    s_product_ok = false;
    s_reported_mismatch = 0;
    s_last_rx_us = 0;   // no session, nothing to time out; the next inbound message re-arms it
    s_machine_id[0] = s_machine_name[0] = '\0';
    // NOT calling panel_link_reset_decoder() here, and that is a decision rather than an omission.
    //
    // Two reasons, and the second is the one that matters. First, it would buy nothing: the decoder
    // resyncs on magic-plus-CRC by construction, so a half-frame left over from the old session is
    // stepped over rather than mistaken for a new one — which is the whole point of the framing.
    //
    // ⚠️ Second, TODO(BE): panel_decoder_reset() delegates to panel_decoder_init(), which also zeroes
    // corrupt_frames and discarded_bytes. panel_frame.h describes reset as "forget any partial frame",
    // and app_main prints those two counters precisely because the RATE over a session is the
    // diagnosis. Calling it would silently reset that trend every time a cable moved — the counters
    // would read healthy exactly when someone was investigating. Fixing that belongs in panel_frame.c,
    // which this change is not allowed to touch.
    ESP_LOGI(TAG, "session ended — %s", why);
    // Both of these are turns in flight with nobody on the other end. Voice has audio it can no longer
    // deliver; an update has a half-written slot that must be abandoned rather than left looking live.
    // Neither can notice the session ending on its own — this is the one place that knows.
    voice_link_lost();
    fw_abort(why);
    display_lock();
    ui_set_connected(false);
    ui_enter_remote_offline();   // the Overview becomes the "open Grid on this computer" guide
    display_unlock();
}

// ── HANDLERS ────────────────────────────────────────────────────────────────────────────────────────

// Apply one project, in the shape panel-protocol.md §2 describes. `agent`, `model` and `recap` are omitted
// rather than sent as null when absent, so an empty string here means "the app did not say".
//
// FOUR calls where the reference's project fetch has one struct assignment, because the reference owns
// both halves and this one does not: ui_tile_set_name is also what CREATES the tile, so the order
// matters — everything after it addresses a project that now exists.
static void apply_tile(const cJSON *j)
{
    const char *id = jstr(j, "id");
    if (!id[0]) return;
    ui_tile_set_name(id, jstr(j, "name"));
    // After the name, because ui_tile_set_name is what CREATES the tile.
    ui_tile_set_project(id, jstr(j, "project"));
    ui_tile_set_engine(id, jstr(j, "agent"));
    ui_tile_set_selected_model(id, jstr(j, "model"));
    // A tile with a recap already on it is not overwritten by the list: a turn that has since finished put
    // something fresher there. Restore rather than emit, so a project that is busy right now keeps its
    // Working row (ui_tile_restore_event never touches the live lifecycle).
    //
    // BOTH zones, and as `summary` rather than `done`. Two things were wrong here and both showed on every
    // cold start: `done` is the kind of a finished STEP, so the card came up green with a tick; and passing
    // the headline as the body with no 4th argument left the tile and the reader drawing ONE string — which
    // is why "the recap and the summary are the same sentence" was the first thing anyone noticed after a
    // replug. The headline goes in the headline slot, where it is drawn unclipped; `summary` is the body
    // behind it, and when the app has none the headline stands in for both.
    const char *recap = jstr(j, "recap");
    const char *summary = jstr(j, "summary");
    if (recap[0] && !ui_tile_has_event(id)) {
        // The body goes in EMPTY when the app has none, rather than being filled with the headline. The
        // reader then says there is no long form yet (READER_NO_BODY) instead of drawing the same
        // sentence the tile is already showing — which is what "the recap and the summary are the same"
        // looked like on 2026-08-18, and it was this line manufacturing it.
        ui_tile_restore_event(id, "summary", summary, recap);
    }
    // The tint. An unrecognised value is drawn as `done` by ui_tile_set_recap_kind, never as an error —
    // guessing "failed" on a turn that worked is the worse of the two mistakes.
    const char *rk = jstr(j, "recapKind");
    if (rk[0]) ui_tile_set_recap_kind(id, rk);
    // busy comes from the list too, for a panel that plugged in mid-turn. "processing" with no step text
    // falls back to the rotating gerund until the first turn.parts arrives.
    if (jbool(j, "busy")) ui_tile_emit(id, "processing", "", NULL);
}

static void on_welcome(const cJSON *root)
{
    // WHOSE APP IS THIS? Answered first, before the protocol number, because a foreign app's protocol
    // number is not a mismatch to report — it is a number from another lineage that means nothing here,
    // and reporting it would put "Panel needs an update" on the screen over a perfectly healthy panel.
    //
    // A POSITIVE match, so ABSENCE MEANS NO: reading a missing field as "probably mine" puts the whole
    // hole back, because the app that predates the field is exactly the one that can still capture this
    // board. This board is also the Harness dial and its daemon can open this port too (PANEL_PRODUCT).
    //
    // What it gates is s_product_ok, and through it `fw.offer` — NOT s_connected. The two are separate
    // on purpose: a protocol mismatch deliberately leaves s_connected false while the app reflashes the
    // panel over that very disagreement, so gating firmware on a live session would disable the one
    // path that repairs a stale panel.
    //
    // Silent. There is no answer to send someone else's app, and nothing on the glass to change: the
    // user's own app may be one retry away and a warning screen would outlive it. ESP_LOGD, not W, for
    // the same reason — a foreign daemon greets on a timer, and this must not become the log.
    const char *product = jstr(root, "product");
    if (strcmp(product, PANEL_PRODUCT) != 0) {
        s_product_ok = false;
        ESP_LOGD(TAG, "welcome from product \"%s\", not " PANEL_PRODUCT " — ignored", product);
        return;
    }
    s_product_ok = true;
    const int proto = jint(root, "proto");
    const cJSON *machine = cJSON_GetObjectItemCaseSensitive(root, "machine");
    char id[sizeof(s_machine_id)], name[sizeof(s_machine_name)];
    snprintf(id,   sizeof(id),   "%s", jstr(machine, "id"));
    snprintf(name, sizeof(name), "%s", jstr(machine, "name"));

    // The language grid-app transcribes in, for the Settings page's Voice row. Applied BEFORE the keepalive
    // return below, not after: it refreshes a label in place and costs nothing, and putting it after would
    // mean a machine whose locale changed only told the panel on the next reconnect.
    ui_set_voice_lang(jstr(root, "voiceLang"));

    // The keepalive hello (see HELLO_KEEPALIVE_MS) earns a welcome every 15 s in the steady state, and
    // treating each of those as a fresh connection would re-request the project list, rebuild every tile
    // and snap the carousel back to the first one — every 15 seconds, while someone is looking at the
    // third. Same machine, same protocol, already connected: nothing happened.
    if (s_connected && proto == PANEL_PROTO_VERSION && strcmp(id, s_machine_id) == 0) {
        ESP_LOGD(TAG, "welcome (keepalive) from %s", s_machine_id);
        return;
    }

    memcpy(s_machine_id,   id,   sizeof(s_machine_id));
    memcpy(s_machine_name, name, sizeof(s_machine_name));

    if (proto != PANEL_PROTO_VERSION) {   // NOLINT — see the note below
        // A STATE, not an error to swallow (panel-protocol.md §2). The app carries the firmware image and can
        // offer to reflash this panel over the same cable it is disagreeing on, so the one useful thing
        // the panel can do is say so where someone will read it.
        //
        // Reported ONCE per distinct version. The hello retry keeps running while a mismatch stands (the
        // session never opens, so the 2 s cadence applies) and each answer lands here — rebuilding the
        // same screen and reprinting the same warning twice a second would drown the log that explains it.
        s_connected = false;
        if (s_reported_mismatch != proto) {
            s_reported_mismatch = proto;
            ESP_LOGW(TAG, "protocol mismatch: grid-app speaks %d, this firmware speaks %d",
                     proto, PANEL_PROTO_VERSION);
            char detail[120];
            snprintf(detail, sizeof(detail),
                     "Grid speaks version %d and this panel speaks %d.\nGrid can reflash it over this cable.",
                     proto, PANEL_PROTO_VERSION);
            display_lock();
            ui_show_error("Panel needs an update", detail);
            display_unlock();
        }
        return;
    }
    s_reported_mismatch = 0;

    ESP_LOGI(TAG, "welcome from %s (app %s, machine id %s)",
             s_machine_name[0] ? s_machine_name : "an unnamed machine",
             jstr(root, "app"), s_machine_id);
    s_connected = true;
    display_lock();
    ui_set_machine_name(s_machine_name);
    ui_set_connected(true);
    ui_leave_error_screen();          // a stale mismatch screen must not outlive the session that fixed it
    ui_leave_remote_offline_loading();
    display_unlock();
    // Outside the lock: this writes to USB and can block for the link's write timeout, and holding the
    // LVGL mutex across that would stall every repaint on the panel for as long as the host is quiet.
    send_projects_list();
}

// The whole list, which is also the only thing that may REMOVE a tile.
//
// Held under ONE display_lock for the whole reconcile, which is the reference's own rule and worth
// repeating here: with the huge-range circular carousel every add and remove re-anchors the scroll to
// keep the viewed project centred, so locking per ui_* call would let the LVGL task render between them
// and the viewed tile would visibly wobble. The recursive lock makes the poll render as ONE transition.
static void on_chats(const cJSON *root)
{
    const cJSON *items = cJSON_GetObjectItemCaseSensitive(root, "items");
    int n = 0, seen = 0;
    const cJSON *it = NULL;

    display_lock();
    cJSON_ArrayForEach(it, items) {
        seen++;
        // A project with no id cannot be addressed by any later message — turn.started, turn.parts and
        // turn.stop all key on it — so a tile for it could only ever be a tile that never updates.
        const char *id = jstr(it, "id");
        if (!id[0] || n >= MAX_TILES) continue;
        snprintf(s_ids[n], sizeof(s_ids[0]), "%s", id);
        n++;
        apply_tile(it);
    }
    // Removals, from the END so ui_tile_remove can shift the model without a snapshot of every id.
    for (int i = ui_tile_count() - 1; i >= 0; i--) {
        char cur[ID_MAX];
        if (!ui_tile_id_at(i, cur, sizeof(cur))) continue;
        bool present = false;
        for (int j = 0; j < n; j++) if (strcmp(cur, s_ids[j]) == 0) { present = true; break; }
        if (!present) ui_tile_remove(cur);
    }
    // ...and now the ORDER, which the two steps above do not touch: the walk matches tiles by id and the
    // append lands at the end, so without this the ring keeps whatever order the tiles first arrived in.
    // The app's list is the sidebar's — pinned first, most recently spoken in first — and it resends the
    // whole thing whenever that moves, which is the only reason there is anything here to apply.
    _Static_assert(ID_MAX == 48, "ui_tiles_reorder spells the id width out — keep it equal to ID_MAX");
    ui_tiles_reorder(s_ids, n);

    // The list is built: drop the boot spinner and land on a project (or stay on the empty page).
    ui_land_after_reload();
    display_unlock();
    if (seen > n) ESP_LOGW(TAG, "projects: %d sent, %d usable", seen, n);
}

static void on_chat_updated(const cJSON *root)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, "item");
    if (!cJSON_IsObject(item) || !jstr(item, "id")[0]) { s_bad++; return; }
    display_lock();
    apply_tile(item);
    display_unlock();
}

// The turn so far, as one ordered timeline, sent WHOLE on every change (never as a delta — the app's own
// run object is replaced wholesale upstream and a step mutates in place as it finishes, so there is no
// append-only stream underneath to mirror).
//
// **The order is the message.** An agent says a sentence, runs a command, reads the result, says the next
// sentence. What the panel keeps out of that is deliberately narrow — the LAST main step, every SUB-AGENT
// step, and the plan — because the well is ~290px and the question a panel across a desk answers is "what
// is it saying, and what is it doing", not "what did it do nine steps ago".
//
// A step's `status` is read for the todos only, and there the rule is absolute: **anything unrecognised is
// FINISHED, never running.** A reader that treats an unknown status as `running` leaves a spinner turning
// forever on a turn that ended. The tile's own busy state is driven by the PROJECT, which turn.done and
// turn.error both close, so a step stuck at `unknown` cannot outlive its turn on this screen either.
static void on_turn_parts(const cJSON *root)
{
    const char *chat_id = jstr(root, "chatId");
    if (!chat_id[0]) { s_bad++; return; }
    const cJSON *parts = cJSON_GetObjectItemCaseSensitive(root, "parts");

    // The last MAIN step (no `parent`) — what the tile's centred line names.
    const char *step_label = "", *step_tool = "", *step_arg = "", *step_kind = "";
    // Sub-agent rows, built as we walk so the order of the timeline survives into the band.
    cJSON *subs = cJSON_CreateArray();
    int n_subs = 0;

    const cJSON *part = NULL;
    cJSON_ArrayForEach(part, parts) {
        const char *k = jstr(part, "k");
        // `k:"t"` is a passage the agent WROTE. Not drawn here: a running turn hides the recap card and
        // shows one centred line (the Working frame), so streaming prose would both draw something the
        // design does not draw and — because project_apply_event treats any kind but "processing" as the
        // END of a turn — end the turn on every part. The prose arrives with turn.done.
        if (strcmp(k, "s") != 0) continue;

        const char *parent = jstr(part, "parent");
        if (!parent[0]) {
            step_label = jstr(part, "label");
            step_tool  = jstr(part, "tool");
            step_arg   = jstr(part, "arg");
            step_kind  = jstr(part, "kind");
            continue;
        }

        // A step with a `parent` is a sub-agent's work and is drawn on the sub-agent band.
        //
        // ⚠️ THE WIRE CARRIES NO SUB-AGENT TYPE. The reference's rows read "› Explore" because its backend
        // pre-formatted the delegated agent's NAME into the row; `turn.parts` has `parent`, which is the id
        // of the step that spawned this one, and nothing that names what the sub-agent IS. So the row gets
        // a gerund — the same vocabulary the Working line uses — picked from the step's own `t0` so it is
        // stable for the life of that step instead of flickering on every re-send.
        if (n_subs >= 6) continue;
        const int t0 = jint(part, "t0");
        const char *status = jstr(part, "status");
        const bool running = strcmp(status, "running") == 0;   // anything else is finished
        char row[96];
        const char *gerund = panel_gerund(t0);
        if (running) snprintf(row, sizeof(row), "\xE2\x80\xBA %s\xE2\x80\xA6", gerund);          // › Cooking…
        else         snprintf(row, sizeof(row), "\xE2\x9C\x93 %s", gerund);                     // ✓ Cooking
        cJSON *e = cJSON_CreateObject();
        if (!e) continue;
        cJSON_AddStringToObject(e, "text", row);
        cJSON_AddStringToObject(e, "color", running ? "#ff8a4c" : "#35c46a");
        cJSON_AddItemToArray(subs, e);
        n_subs++;
    }

    display_lock();
    // `processing` first: it is what CREATES the busy row, and it is also the only thing stamping the
    // tile's liveness — ui_prune_stale_busy clears a project whose stamps stop arriving.
    ui_tile_emit(chat_id, "processing", step_label, NULL);
    // Then the detail, which needs the busy row to exist.
    if (step_tool[0]) ui_tile_set_tool(chat_id, step_tool, step_label, step_kind, step_arg);
    ui_tile_set_agents(chat_id, n_subs > 0 ? subs : NULL);
    // `todos` rides the MESSAGE, not the parts — it is the state of a plan, not a point in the story.
    // ABSENT means the agent has no plan, which is different from an empty plan and is drawn as nothing.
    const cJSON *todos = cJSON_GetObjectItemCaseSensitive(root, "todos");
    ui_tile_set_todos(chat_id, cJSON_IsArray(todos) ? todos : NULL);
    display_unlock();
    cJSON_Delete(subs);
}

// grid-app heard something. Either it knows where it goes, or it wants to be told.
static void on_voice_transcript(const cJSON *root)
{
    const char *route_id = jstr(root, "routeId");
    const char *text     = jstr(root, "text");
    const bool  confirm  = jbool(root, "needsConfirm");
    // The turn is over as far as the capture task is concerned either way — this IS the answer it was
    // waiting for, whether or not it settles the routing.
    voice_reply_seen();
    ESP_LOGI(TAG, "voice.transcript route=%s confirm=%d: %s", route_id, (int)confirm, text);
    display_lock();
    // needsConfirm is the ONLY guard between a guessed route and a turn dispatched into a real
    // repository (panel-protocol.md §2). A panel that showed the transcript and let the app get on with it
    // would defeat it just as completely as one that dispatched itself.
    const char *pid = jstr(root, "chatId");
    ui_voice_routed(!confirm, !pid[0], route_id, pid, text);
    display_unlock();
}

static void on_voice_error(const cJSON *root)
{
    const char *message = jstr(root, "message");
    voice_reply_seen();
    ESP_LOGW(TAG, "voice.error: %s", message);
    display_lock();
    // The app's sentence, shown as it is. panel-protocol.md §2 asks for "a sentence a person can act on" here,
    // and replacing it with a generic one on this side would throw away the only side that knows what
    // actually went wrong — whether the transcriber was unreachable, or unauthorised, or heard nothing.
    ui_voice_route_abort();   // drop the loading overlay now, rather than waiting out the routing watchdog
    ui_show_error("Voice failed", message[0] ? message : "Grid could not transcribe that.");
    display_unlock();
}

// ── DISPATCH ────────────────────────────────────────────────────────────────────────────────────────

static void handle_json(const uint8_t *payload, size_t len)
{
    // ParseWithLength, not Parse: the payload points into the decoder's buffer and is NOT NUL-terminated.
    // Copying it to terminate it would mean an 8 KB copy on a 4 KB task stack, or a heap allocation on
    // the receive path of a device that must not fail one.
    cJSON *root = cJSON_ParseWithLength((const char *)payload, len);
    if (!root) {
        s_bad++;
        ESP_LOGW(TAG, "unreadable JSON payload (%u bytes), discarded", (unsigned)len);
        return;
    }
    const char *t = jstr(root, "t");
    if (!t[0]) {
        s_bad++;
        ESP_LOGW(TAG, "message with no \"t\", discarded");
        cJSON_Delete(root);
        return;
    }
    // ANY readable message is a sign of life, not only `ping`. Stamped before the dispatch so a handler
    // that blocks (a screenshot, a firmware slice) cannot make the link look dead while it works.
    note_inbound();

    if      (strcmp(t, "welcome") == 0)         on_welcome(root);
    else if (strcmp(t, "chats") == 0)        on_chats(root);
    else if (strcmp(t, "chat.updated") == 0) on_chat_updated(root);
    else if (strcmp(t, "turn.parts") == 0)      on_turn_parts(root);
    else if (strcmp(t, "ping") == 0) {
        // The heartbeat, every 5 s. note_inbound() above has already done this side's half of the work —
        // it is what keeps the panel from deciding the app has gone quiet — and the answer does the other
        // side's: see send_pong() for the host-side failure that has no other symptom.
        send_pong();
    } else if (strcmp(t, "turn.started") == 0) {
        // Anchors the clock. Every step's `t0` is measured from this instant, and the device counts from
        // here rather than stamping a step when it first sees one — `onAttach` re-sends the whole timeline
        // after a panel reboot, and stamping would make every step read as having just begun.
        ui_tile_turn_started(jstr(root, "chatId"));
    } else if (strcmp(t, "turn.done") == 0) {
        const char *pid = jstr(root, "chatId"), *recap = jstr(root, "recap");
        display_lock();
        // `recap` is both halves here: the headline AND the body. grid-app sends one line (the last thing
        // the agent said, cut to a line), so passing it as `recap` as well would print the same sentence
        // twice — see the two-zone rule in project_apply_event.
        //
        // Emitted as `summary`, NOT as `done`, and the difference is visible on the glass. `kind_style`
        // gives `done` a green ✓, which is right for the thing that kind means in the reference — a STEP
        // completing, the same mark a finished sub-agent wears. A recap is not a step: it is the tile's
        // main readable content, the sentence someone walks over to read. `summary` is the kind the
        // reference already reserved for exactly that, and its own comment says why — "neutral, not
        // alarming green". Reported from the desk 2026-08-17: a finished task drew its recap green.
        //
        // The empty case still goes through `done`, and the literal string matters: a turn can be stopped
        // before the assistant says anything, and `project_apply_event` matches a bare "done" to clear the
        // Processing row while KEEPING the last real card. Sent as an empty `summary` it would instead
        // replace a perfectly good recap with a blank one.
        // The recap rides as BOTH the body and the headline (4th argument). As the headline it is drawn
        // unclipped, which is the point of a ≤15-word budget; as the body it gives the reader something
        // to show for the seconds before `summary` lands, and for the turns where it never does.
        if (recap[0]) ui_tile_emit(pid, "summary", recap, recap);
        else          ui_tile_emit(pid, "done", "done", NULL);
        // How it ENDED still comes from the list's `recapKind` — the `project.updated` that follows a
        // finished turn is what paints a failure red or a stop grey, on top of this neutral default.
        display_unlock();
        // ⚠️ This can arrive for a project the panel does not think is running — after a panel reboot
        // mid-turn, for instance. It means "that project is idle now", not that something went wrong.
        ui_notify_task_done(pid);   // wake / badge / open the drawer, depending on what is on screen
        audio_notify_done();
    } else if (strcmp(t, "focus") == 0) {
        // The window switched chats — bring the carousel to the same one, so the desk shows one thing.
        //
        // Recorded as ALREADY SENT before moving. apply_active_from_col runs on the way and would
        // otherwise notice a new centred tile and report it straight back to grid-app, which is a loop
        // that only ends because the id stops changing. Writing it here ends it on the first lap; the
        // app's own side does the same, so neither depends on the other being careful.
        //
        // A tile this panel does not have is ignored: the app is ahead of the list this panel was sent,
        // and the `chats` that brings the tile will arrive on its own.
        ui_focus_tile_from_app(jstr(root, "chatId"));
    } else if (strcmp(t, "turn.summarizing") == 0) {
        // The agent has stopped working and its headline is being written. Arrives INSTEAD of `turn.done`,
        // so the tile must stay exactly as it is — working — until there is something true to put there.
        // A placeholder recap that changes a few seconds later is not missing information, it is WRONG
        // information, on a screen someone is reading from across the room.
        //
        // Mapped onto `processing`, which is the same state the turn was already in and the same one the
        // reference used for its trailing "Summarizing…" window. That also re-stamps `busy_last_ms`, so
        // the 25s stale-busy sweep does not fire in the middle of it — and still fires if the app dies
        // here, which is the whole reason that sweep exists.
        ui_tile_emit(jstr(root, "chatId"), "processing", NULL, NULL);
    } else if (strcmp(t, "summary") == 0) {
        // The long form of the last recap, and a SEPARATE message on purpose: the app writes it by asking
        // a model, which takes seconds, and holding turn.done for it would leave a tile spinning on work
        // that has already finished. So the order is always turn.done first, summary maybe — it can fail
        // to arrive at all, and the detail screen then simply keeps showing the one-line recap.
        //
        // KEYED TO THE PROJECT, NOT TO THE OUTCOME: it can follow `turn.error` as well as `turn.done`,
        // because a turn that failed halfway may still have said enough to be worth reading. Nothing here
        // asks how the turn ended.
        //
        // It arrives AFTER `turn.done`, which already carried the ≤15-word headline and put the tile back
        // to rest. This is only the ≤120-word body behind it, so it touches the reader and NOT the card:
        // `set_summary` replaces `m_full` and repaints a reader that happens to be open on this project,
        // leaving the headline the tile is drawing exactly where it is.
        ui_tile_set_summary(jstr(root, "chatId"), jstr(root, "text"));
    } else if (strcmp(t, "question") == 0) {
        ui_question_show(jstr(root, "chatId"), jstr(root, "id"), jstr(root, "summary"),
                         jstr(root, "command"),
                         cJSON_GetObjectItemCaseSensitive(root, "options"));
    } else if (strcmp(t, "question.cancel") == 0) {
        // Fires whenever the OTHER surface settles it first, and when the app's own timer gives up (55 s
        // today; the agent stops waiting at 60). A panel that ignored it would hold a dead card forever.
        ui_question_cancel(jstr(root, "chatId"), jstr(root, "id"));
    } else if (strcmp(t, "voice.transcript") == 0) {
        on_voice_transcript(root);
    } else if (strcmp(t, "voice.error") == 0) {
        on_voice_error(root);
    } else if (strcmp(t, "fw.offer") == 0) {
        // The decision is fw_update's, including the decision to say nothing at all. Note what is NOT
        // here: any state kept about a declined offer. panel-protocol.md §2 says the app re-offers on the next
        // `hello`, which is fifteen seconds away, so remembering one would only be a second opinion that
        // could disagree with the app's.
        //
        // GATED ON THE PRODUCT, and this is the gate that matters most on this side. Everything else a
        // foreign app could send draws something wrong on a screen; this one writes to flash and reboots.
        // s_product_ok is false until a `welcome` names PANEL_PRODUCT, so an app that never greeted, or
        // greeted as something else, cannot reach fw_on_offer at all.
        if (!s_product_ok) {
            ESP_LOGW(TAG, "fw.offer before any " PANEL_PRODUCT " welcome — refused");
        } else {
            fw_on_offer(jstr(root, "version"), jint(root, "size"), jstr(root, "sha256"));
        }
    } else if (strcmp(t, "scrolltest") == 0) {
        ui_scroll_benchmark(jint(root, "passes"));   // development instrument — see ui_scroll_benchmark
    // ⚠️ NO `screenshot` CASE, and it is worth knowing why rather than rediscovering it. The predecessor
    // firmware answered one by walking its FRAME BUFFER and streaming the rows back as base64 — that is
    // how LVGL's own perf-monitor overlay was caught still running from a debugging session: it was in the
    // picture. This board has no frame buffer to walk. The CO5300 keeps the image in its own GRAM and LVGL
    // renders in PARTIAL mode into two small internal DMA buffers (display.c), so there is nowhere to read
    // the screen back from. Doing it here would mean lv_snapshot_take() into a ~434 KB PSRAM surface, which
    // is a real feature and not a line to slip in. TODO(BE): worth building — "let a human look at it" is
    // the current answer and it does not scale to a change nobody is holding the panel for.
    } else if (strcmp(t, "turn.error") == 0) {
        ESP_LOGW(TAG, "turn.error on %s: %s", jstr(root, "chatId"), jstr(root, "message"));
        display_lock();
        ui_tile_emit(jstr(root, "chatId"), "error", jstr(root, "message"), NULL);
        display_unlock();
    } else {
        // NOT an error. A grid-app running ahead of this firmware is a version mismatch someone can act
        // on; counting it keeps that visible in the telemetry line instead of it reading as a link that
        // connected and then went quiet.
        s_unknown++;
        ESP_LOGI(TAG, "no case for message \"%s\" — ignored", t);
    }
    cJSON_Delete(root);
}

// Every decoded frame, on the LINK task, with `payload` pointing into the decoder's own buffer — valid
// for this call only. Anything that must outlive it is copied; anything touching LVGL takes
// display_lock() first, which the handlers above do around their ui_* calls.
static void on_frame(uint8_t version, uint8_t type, const uint8_t *payload, size_t len, void *ctx)
{
    (void)version;
    (void)ctx;
    if (type == PANEL_TYPE_JSON) { handle_json(payload, len); return; }
    if (type == PANEL_TYPE_FW) {
        // Written straight to flash from here, on this task — so this call BLOCKS THE READER for the
        // ~16 ms the write takes, and nothing is draining the port meanwhile.
        //
        // That is safe only because two other numbers make it safe, and it is worth naming them here
        // because this line is where they get spent: the app may have at most one 16 KB credit window in
        // flight (docs/panel-protocol.md), and the RX ring holds twice that. This comment used to claim the
        // blocking write *was* the flow control — that the host could not outrun the writer. The opposite
        // is true. This peripheral never NAKs; whatever does not fit the ring is dropped in the ISR with
        // nobody told (panel_link.c). Not reading is what loses the data, and it cost a transfer that
        // wrote 0 of 1342160 bytes to find out.
        fw_on_slice(payload, len);
        return;
    }
    // Surfaced with its raw type byte rather than dropped (panel-protocol.md §1). PCM travels device→app, so a
    // PCM frame arriving here is a peer doing something this build has never heard of — worth counting,
    // not worth panicking about.
    s_unknown++;
    ESP_LOGI(TAG, "frame type 0x%02X (%u bytes) has no reader here", type, (unsigned)len);
}

// ── THE HANDSHAKE / LIVENESS TASK ───────────────────────────────────────────────────────────────────

static void hello_task(void *arg)
{
    (void)arg;
    bool had_host = false;
    for (;;) {
        const bool host = panel_link_host_present();
        if (!host) {
            // The cable left, or the machine went to sleep. This is the one session end the device can
            // see in hardware; the heartbeat below catches the far more common one.
            if (had_host) session_lost("the USB host went away");
        } else {
            if (!had_host) ESP_LOGI(TAG, "usb host present — saying hello");
            // SAID EVEN WHILE OFFLINE, and that is the point of the loop rather than a side effect of it.
            // grid-app may start at any moment and it cannot see this panel until the panel speaks: there
            // is no port-open event on this side, and usb_serial_jtag_is_connected() is true of any
            // running computer with the lead in. So `hello` keeps going out until someone answers
            // (docs/panel-protocol.md, "Heartbeat": "the panel re-sends hello periodically").
            send_hello();
        }
        // ── THE APP HAS GONE QUIET ──────────────────────────────────────────────────────────────────
        // Fifteen seconds with no message OF ANY KIND. Not fifteen seconds without a `ping`: any inbound
        // message is a sign of life (note_inbound), so a link busy with turn.parts never trips this even
        // if the heartbeat itself is late.
        //
        // This is the failure the cable cannot show us. The app quitting with the lead still in leaves a
        // USB host present, a port that still accepts writes into a buffer nobody drains, and a panel
        // showing tiles for a machine that has stopped listening.
        if (s_connected && s_last_rx_us &&
            (esp_timer_get_time() - s_last_rx_us) > (int64_t)SILENCE_IS_GONE_MS * 1000) {
            session_lost("grid-app went quiet");
        }
        // Riding on this loop rather than getting a task of its own: fw_update has no thread, the only
        // thing it needs is to be asked "has anything arrived lately", and this loop already runs at a
        // cadence (2 s / 15 s) far finer than the 30 s it is measuring.
        fw_tick();
        had_host = host;
        // 2 s while there is no session so plugging in feels immediate; 15 s once there is one, where it
        // is only a fallback. The silence check above runs on whichever period is current, so an offline
        // panel re-checks often and a live one cheaply.
        vTaskDelay(pdMS_TO_TICKS(s_connected ? HELLO_KEEPALIVE_MS : HELLO_PERIOD_MS));
    }
}

// ── PUBLIC ──────────────────────────────────────────────────────────────────────────────────────────

bool panel_client_start(void)
{
    // No callback wiring, where the previous version of this file handed the screens three function
    // pointers. The reference's screens call commander_* directly and this one calls panel_client_*
    // directly; the indirection bought a UI that could build without the link, which nothing needed and
    // which cost a reader one hop at every call site.
    display_lock();
    ui_set_connected(false);
    display_unlock();

    if (!panel_link_start(on_frame, NULL)) return false;

    if (xTaskCreate(hello_task, "panel_hello", HELLO_STACK, NULL, 4, NULL) != pdPASS) {
        // The link is up and will still deliver anything grid-app sends unprompted, but without the
        // handshake nothing ever asks — so say what was actually lost rather than "task create failed".
        ESP_LOGE(TAG, "handshake task create failed — the panel will never say hello");
        return false;
    }
    return true;
}

bool panel_client_is_connected(void)
{
    return s_connected;
}

void panel_client_counters(uint32_t *bad, uint32_t *unknown)
{
    if (bad)     *bad     = s_bad;
    if (unknown) *unknown = s_unknown;
}
