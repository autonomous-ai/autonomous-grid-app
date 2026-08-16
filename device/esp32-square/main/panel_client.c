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
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "fw_update.h"
#include "panel_link.h"
#include "ui_screens.h"
#include "ui_screenshot.h"
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
// This is the one piece of behaviour here that docs/protocol.md does not legislate, so it is spelled
// out. §2 calls `hello` "the first thing after the port opens" and says nothing about repeating it.
// Without a repeat, grid-app quitting and restarting with the cable still in wedges the panel forever:
// the app's port opens with no hello to answer, and the panel is waiting for a welcome that only a
// hello would have triggered. There is no heartbeat in the protocol to notice that with.
//
// Re-sending is not a new message, a new field or a changed meaning — the app answers `welcome` and the
// session simply re-establishes. It also doubles as the only liveness probe this side has: a send that
// fails is the host not draining the port, which ends the session (see send_json).
//
// 15 s rather than 2: this is a fallback for a rare event, not a poll.
#define HELLO_KEEPALIVE_MS 15000

// The handshake/liveness task. It only ever builds one small JSON object and hands it to panel_link, so
// this is not the stack the message handlers run on — those run on the link's reader task.
#define HELLO_STACK 3072

// The ids from the last `projects` message, kept only long enough to reconcile removals against what the
// UI already holds.
//
// A file-scope array in PSRAM BSS rather than a local: at MAX_PROJECTS this is several KB and the reader
// task that runs it has a 4 KB stack. It is only ever touched from that one task.
static EXT_RAM_BSS_ATTR char s_ids[MAX_PROJECTS][ID_MAX];

// volatile: written on one task and read on another (the handshake task decides a session ended, the
// link task and the UI read the result), and not worth a mutex — a stale read costs one loop period.
static volatile bool s_connected;     // `welcome` seen, session believed live
static uint32_t s_bad;
static uint32_t s_unknown;
static char     s_machine_id[64];
static char     s_machine_name[64];
static int      s_reported_mismatch;  // the app protocol already shown on screen; 0 = none

// ── JSON, leniently ─────────────────────────────────────────────────────────────────────────────────
// protocol.md §2: unknown keys are ignored, and a missing key falls back to a zero value rather than
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
// protocol.md §2 leans on these being the same string: `mac` is "also the device's USB serial number, so
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

    // And how hard the screen has been working since the last one of these. `fps` is flushes per second
    // and `kpxs` is thousands of pixels per second, so `kpxs*1000/fps` is the average area repainted per
    // frame — which is the number that diagnoses a stutter and the one no amount of looking provides.
    // A carousel that is accidentally full-screen and one that is not look identical until it is divided.
    uint32_t fl = 0, px = 0, ms = 0, busy = 0;
    display_draw_stats(&fl, &px, &ms, &busy);
    if (ms) {
        cJSON_AddNumberToObject(m, "fps", (double)fl * 1000.0 / (double)ms);
        cJSON_AddNumberToObject(m, "kpxs", (double)px / (double)ms);
        cJSON_AddNumberToObject(m, "cpu", (double)busy * 100.0 / (double)ms);
    }
    send_json(m);
}

static void send_projects_list(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "projects.list");
    send_json(m);
}

void panel_client_send_turn(const char *project_id, const char *text)
{
    if (!project_id || !project_id[0] || !text || !text[0]) return;
    cJSON *m = cJSON_CreateObject();
    cJSON_AddStringToObject(m, "t", "turn.send");
    cJSON_AddStringToObject(m, "projectId", project_id);
    cJSON_AddStringToObject(m, "text", text);
    send_json(m);
}

void panel_client_stop_project(const char *project_id)
{
    if (!project_id || !project_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "turn.stop");
    cJSON_AddStringToObject(m, "projectId", project_id);
    ESP_LOGI(TAG, "turn.stop %s", project_id);
    send_json(m);
}

// ── VOICE, OUTBOUND ─────────────────────────────────────────────────────────────────────────────────

void panel_client_voice_begin(const char *project_id, voice_cmd_t cmd)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "voice.begin");
    // OMITTED, not empty. protocol.md §2 makes `projectId` optional and absence is the message: it tells
    // grid-app the user spoke from a screen that names no project, so it has to route the transcript
    // itself and ask. An empty string would be a project id — one that matches nothing.
    if (project_id && project_id[0]) cJSON_AddStringToObject(m, "projectId", project_id);
    // Same rule for the modifier: VOICE_CMD_NONE sends no `cmd` key at all rather than "none", so a
    // plain turn and a modified one differ by a field being there, not by its value.
    if (cmd == VOICE_CMD_GOAL)      cJSON_AddStringToObject(m, "cmd", "goal");
    else if (cmd == VOICE_CMD_LOOP) cJSON_AddStringToObject(m, "cmd", "loop");
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

void panel_client_voice_confirm(const char *route_id, const char *project_id)
{
    if (!route_id || !project_id || !project_id[0]) return;
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "voice.confirm");
    cJSON_AddStringToObject(m, "routeId", route_id);
    cJSON_AddStringToObject(m, "projectId", project_id);
    ESP_LOGI(TAG, "voice.confirm route=%s → %s", route_id, project_id);
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
    // "a sentence a person can act on" is what protocol.md asks of voice.error; the same standard is
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
    s_reported_mismatch = 0;
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

// Apply one project, in the shape protocol.md §2 describes. `agent`, `model` and `recap` are omitted
// rather than sent as null when absent, so an empty string here means "the app did not say".
//
// FOUR calls where the reference's project fetch has one struct assignment, because the reference owns
// both halves and this one does not: ui_project_set_name is also what CREATES the tile, so the order
// matters — everything after it addresses a project that now exists.
static void apply_project(const cJSON *j)
{
    const char *id = jstr(j, "id");
    if (!id[0]) return;
    ui_project_set_name(id, jstr(j, "name"));
    ui_project_set_engine(id, jstr(j, "agent"));
    ui_project_set_selected_model(id, jstr(j, "model"));
    // A tile with a recap already on it is not overwritten by the list: `recap` is one line, and a turn
    // that has since finished put something fuller there. Restore rather than emit, so a project that is
    // busy right now keeps its Working row (ui_project_restore_event never touches the live lifecycle).
    const char *recap = jstr(j, "recap");
    if (recap[0] && !ui_project_has_event(id)) ui_project_restore_event(id, "done", recap, NULL);
    // busy comes from the list too, for a panel that plugged in mid-turn. "processing" with no step text
    // falls back to the rotating gerund until the first turn.parts arrives.
    if (jbool(j, "busy")) ui_project_emit(id, "processing", "", NULL);
}

static void on_welcome(const cJSON *root)
{
    const int proto = jint(root, "proto");
    const cJSON *machine = cJSON_GetObjectItemCaseSensitive(root, "machine");
    char id[sizeof(s_machine_id)], name[sizeof(s_machine_name)];
    snprintf(id,   sizeof(id),   "%s", jstr(machine, "id"));
    snprintf(name, sizeof(name), "%s", jstr(machine, "name"));

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
        // A STATE, not an error to swallow (protocol.md §2). The app carries the firmware image and can
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
static void on_projects(const cJSON *root)
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
        if (!id[0] || n >= MAX_PROJECTS) continue;
        snprintf(s_ids[n], sizeof(s_ids[0]), "%s", id);
        n++;
        apply_project(it);
    }
    // Removals, from the END so ui_project_remove can shift the model without a snapshot of every id.
    for (int i = ui_project_count() - 1; i >= 0; i--) {
        char cur[ID_MAX];
        if (!ui_project_id_at(i, cur, sizeof(cur))) continue;
        bool present = false;
        for (int j = 0; j < n; j++) if (strcmp(cur, s_ids[j]) == 0) { present = true; break; }
        if (!present) ui_project_remove(cur);
    }
    // The list is built: drop the boot spinner and land on a project (or stay on the empty page).
    ui_land_after_reload();
    display_unlock();
    if (seen > n) ESP_LOGW(TAG, "projects: %d sent, %d usable", seen, n);
}

static void on_project_updated(const cJSON *root)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, "item");
    if (!cJSON_IsObject(item) || !jstr(item, "id")[0]) { s_bad++; return; }
    display_lock();
    apply_project(item);
    display_unlock();
}

// The turn so far, as one ordered timeline, sent whole on every change.
//
// The panel keeps the LAST passage and the LAST step and throws the rest away. That is a real loss of
// information and it is the right one for this screen: the well is ~290px, the message can carry a
// hundred parts, and the question a panel across a desk answers is "what is it saying, and what is it
// doing" — not "what did it do nine steps ago". The order still matters and is still honoured; only the
// window onto it is one entry wide.
static void on_turn_parts(const cJSON *root)
{
    const char *project_id = jstr(root, "projectId");
    const cJSON *parts = cJSON_GetObjectItemCaseSensitive(root, "parts");
    const char *say = "", *step = "";
    const cJSON *part = NULL;
    cJSON_ArrayForEach(part, parts) {
        const char *k = jstr(part, "k");
        if      (strcmp(k, "t") == 0) say  = jstr(part, "text");
        else if (strcmp(k, "s") == 0) step = jstr(part, "label");
        // Any other `k` is a part kind this firmware has no picture for. Skipped silently rather than
        // counted: the message itself is fine and the rest of it still draws, which is the whole point
        // of the "unknown keys are ignored" rule applied one level down.
    }
    // A step's `status` is deliberately NOT read. protocol.md §2 warns that a reader treating an
    // unrecognised status as `running` leaves a spinner turning forever on a turn that ended — and the
    // way to be immune to that is to have nothing spinning on it. The busy indicator here is driven by
    // the PROJECT's state, which turn.done and turn.error both close, so a step stuck at `unknown`
    // cannot outlive its turn on this screen.
    // Sent as a `processing` frame, which is also what keeps the turn alive: ui_prune_stale_busy clears a
    // tile whose stamps stop arriving, and this is the only thing stamping. The step names the row's verb;
    // the passage is NOT drawn here, because a running turn hides the card entirely and shows one centred
    // line — the panel answers "what is it doing", and the answer it wrote arrives with turn.done.
    (void)say;
    display_lock();
    ui_project_emit(project_id, "processing", step, NULL);
    display_unlock();
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
    // repository (protocol.md §2). A panel that showed the transcript and let the app get on with it
    // would defeat it just as completely as one that dispatched itself.
    const char *pid = jstr(root, "projectId");
    ui_voice_routed(!confirm, !pid[0], route_id, pid, text, 0.0);
    display_unlock();
}

static void on_voice_error(const cJSON *root)
{
    const char *message = jstr(root, "message");
    voice_reply_seen();
    ESP_LOGW(TAG, "voice.error: %s", message);
    display_lock();
    // The app's sentence, shown as it is. protocol.md §2 asks for "a sentence a person can act on" here,
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

    if      (strcmp(t, "welcome") == 0)         on_welcome(root);
    else if (strcmp(t, "projects") == 0)        on_projects(root);
    else if (strcmp(t, "project.updated") == 0) on_project_updated(root);
    else if (strcmp(t, "turn.parts") == 0)      on_turn_parts(root);
    else if (strcmp(t, "turn.started") == 0) {
        display_lock();
        ui_project_emit(jstr(root, "projectId"), "processing", "", NULL);
        display_unlock();
    } else if (strcmp(t, "turn.done") == 0) {
        const char *pid = jstr(root, "projectId"), *recap = jstr(root, "recap");
        display_lock();
        // `recap` is both halves here: the headline AND the body. grid-app sends one line (the last thing
        // the agent said, cut to a line), so passing it as `recap` as well would print the same sentence
        // twice — see the two-zone rule in project_apply_event.
        ui_project_emit(pid, "done", recap[0] ? recap : "done", NULL);
        display_unlock();
        ui_notify_task_done(pid);   // wake / badge / open the drawer, depending on what is on screen
        audio_notify_done();
    } else if (strcmp(t, "voice.transcript") == 0) {
        on_voice_transcript(root);
    } else if (strcmp(t, "voice.error") == 0) {
        on_voice_error(root);
    } else if (strcmp(t, "fw.offer") == 0) {
        // The decision is fw_update's, including the decision to say nothing at all. Note what is NOT
        // here: any state kept about a declined offer. protocol.md §2 says the app re-offers on the next
        // `hello`, which is fifteen seconds away, so remembering one would only be a second opinion that
        // could disagree with the app's.
        fw_on_offer(jstr(root, "version"), jint(root, "size"), jstr(root, "sha256"));
    } else if (strcmp(t, "screenshot") == 0) {
        // A development instrument, answered on this task on purpose: it BLOCKS the reader for the
        // couple of seconds the transfer takes, which is exactly the back-pressure wanted — nothing else
        // should be arriving while the panel is describing itself, and the shot must not be interleaved
        // with a firmware slice. Deliberately NOT on the LVGL task: that is the task that would have to
        // redraw the screen being photographed.
        ui_screenshot_ex(jstr(root, "name"), jint(root, "div"));
    } else if (strcmp(t, "scrolltest") == 0) {
        ui_scroll_benchmark(jint(root, "passes"));
    } else if (strcmp(t, "turn.error") == 0) {
        ESP_LOGW(TAG, "turn.error on %s: %s", jstr(root, "projectId"), jstr(root, "message"));
        display_lock();
        ui_project_emit(jstr(root, "projectId"), "error", jstr(root, "message"), NULL);
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
        // flight (docs/protocol.md), and the RX ring holds twice that. This comment used to claim the
        // blocking write *was* the flow control — that the host could not outrun the writer. The opposite
        // is true. This peripheral never NAKs; whatever does not fit the ring is dropped in the ISR with
        // nobody told (panel_link.c). Not reading is what loses the data, and it cost a transfer that
        // wrote 0 of 1342160 bytes to find out.
        fw_on_slice(payload, len);
        return;
    }
    // Surfaced with its raw type byte rather than dropped (protocol.md §1). PCM travels device→app, so a
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
            // The cable left, or the machine went to sleep. This is the ONE session end the device can
            // see for itself; everything else is inferred from a failed write.
            if (had_host) session_lost("the USB host went away");
        } else {
            if (!had_host) ESP_LOGI(TAG, "usb host present — saying hello");
            send_hello();
        }
        // Riding on this loop rather than getting a task of its own: fw_update has no thread, the only
        // thing it needs is to be asked "has anything arrived lately", and this loop already runs at a
        // cadence (2 s / 15 s) far finer than the 30 s it is measuring.
        fw_tick();
        had_host = host;
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
