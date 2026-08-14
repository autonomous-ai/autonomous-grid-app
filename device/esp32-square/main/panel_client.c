#include "panel_client.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "display.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "panel_link.h"
#include "ui_screens.h"

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

// Parsed `projects` items, staged here before the UI takes them.
//
// A file-scope array in PSRAM BSS rather than a local: at UI_MAX_PROJECTS this is several KB and the
// reader task that runs it has a 4 KB stack. It is only ever touched from that one task.
static EXT_RAM_BSS_ATTR ui_project_t s_staged[UI_MAX_PROJECTS];

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

static void send_hello(void)
{
    char mac[24];
    device_mac(mac, sizeof(mac));
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "hello");
    cJSON_AddStringToObject(m, "fw", PANEL_FW_VERSION);
    cJSON_AddNumberToObject(m, "proto", PANEL_PROTO_VERSION);
    cJSON_AddStringToObject(m, "mac", mac);
    send_json(m);
}

static void send_projects_list(void)
{
    cJSON *m = cJSON_CreateObject();
    if (!m) return;
    cJSON_AddStringToObject(m, "t", "projects.list");
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
    display_lock();
    ui_set_connected(false, NULL);
    display_unlock();
}

// ── HANDLERS ────────────────────────────────────────────────────────────────────────────────────────

// One project, from the shape in protocol.md §2. `agent`, `model` and `recap` are omitted rather than
// sent as null when absent, so an empty string here means "the app did not say".
static void read_project(const cJSON *j, ui_project_t *out)
{
    memset(out, 0, sizeof(*out));
    ui_text_clip(out->id,    sizeof(out->id),    jstr(j, "id"));
    ui_text_clip(out->name,  sizeof(out->name),  jstr(j, "name"));
    ui_text_clip(out->agent, sizeof(out->agent), jstr(j, "agent"));
    ui_text_clip(out->model, sizeof(out->model), jstr(j, "model"));
    ui_text_clip(out->recap, sizeof(out->recap), jstr(j, "recap"));
    out->busy = jbool(j, "busy");
}

static void on_welcome(const cJSON *root)
{
    const int proto = jint(root, "proto");
    const cJSON *machine = cJSON_GetObjectItemCaseSensitive(root, "machine");
    char id[sizeof(s_machine_id)], name[sizeof(s_machine_name)];
    ui_text_clip(id,   sizeof(id),   jstr(machine, "id"));
    ui_text_clip(name, sizeof(name), jstr(machine, "name"));

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

    if (proto != PANEL_PROTO_VERSION) {
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
            display_lock();
            ui_show_version_mismatch(proto, PANEL_PROTO_VERSION);
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
    ui_set_connected(true, s_machine_name);
    display_unlock();
    // Outside the lock: this writes to USB and can block for the link's write timeout, and holding the
    // LVGL mutex across that would stall every repaint on the panel for as long as the host is quiet.
    send_projects_list();
}

static void on_projects(const cJSON *root)
{
    const cJSON *items = cJSON_GetObjectItemCaseSensitive(root, "items");
    int n = 0, seen = 0;
    const cJSON *it = NULL;
    cJSON_ArrayForEach(it, items) {
        seen++;
        if (n >= UI_MAX_PROJECTS) continue;
        // A project with no id cannot be addressed by any later message — turn.started, turn.parts and
        // turn.stop all key on it — so a tile for it could only ever be a tile that never updates.
        if (!jstr(it, "id")[0]) continue;
        read_project(it, &s_staged[n]);
        n++;
    }
    if (seen > n) ESP_LOGW(TAG, "projects: %d sent, %d usable", seen, n);
    display_lock();
    ui_projects_replace(s_staged, n);
    display_unlock();
}

static void on_project_updated(const cJSON *root)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, "item");
    if (!cJSON_IsObject(item) || !jstr(item, "id")[0]) { s_bad++; return; }
    ui_project_t p;
    read_project(item, &p);
    display_lock();
    ui_project_update(&p);
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
    display_lock();
    ui_project_turn_activity(project_id, say, step);
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
        ui_project_turn_started(jstr(root, "projectId"));
        display_unlock();
    } else if (strcmp(t, "turn.done") == 0) {
        display_lock();
        ui_project_turn_done(jstr(root, "projectId"), jstr(root, "recap"));
        display_unlock();
    } else if (strcmp(t, "turn.error") == 0) {
        ESP_LOGW(TAG, "turn.error on %s: %s", jstr(root, "projectId"), jstr(root, "message"));
        display_lock();
        ui_project_turn_error(jstr(root, "projectId"), jstr(root, "message"));
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
    if (type != PANEL_TYPE_JSON) {
        // Surfaced with its raw type byte rather than dropped (protocol.md §1). PCM is the only other
        // code today and it travels device→app, so a PCM frame arriving here is a peer doing something
        // this build has never heard of — worth counting, not worth panicking about.
        s_unknown++;
        ESP_LOGI(TAG, "frame type 0x%02X (%u bytes) has no reader here", type, (unsigned)len);
        return;
    }
    handle_json(payload, len);
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
        had_host = host;
        vTaskDelay(pdMS_TO_TICKS(s_connected ? HELLO_KEEPALIVE_MS : HELLO_PERIOD_MS));
    }
}

// ── PUBLIC ──────────────────────────────────────────────────────────────────────────────────────────

bool panel_client_start(void)
{
    display_lock();
    ui_set_stop_cb(panel_client_stop_project);
    ui_set_connected(false, NULL);
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
