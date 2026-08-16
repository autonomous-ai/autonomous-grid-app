#include "touch.h"
#include "board_pins.h"
#include "board_i2c.h"
#include "display.h"
#include "ui_screens.h"   // ui_swipe_begin/end for the circular edge-swipe
#include "driver/i2c_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_log.h"
#include "lvgl.h"
#include <stdlib.h>

static const char *TAG = "touch";
static esp_lcd_touch_handle_t s_tp;

#define DOUBLE_TAP_MS 500   // two taps within this window (and close in position) = a double-tap. Also the
                            // delay before a single tap opens the detail reader — 500ms so a (slightly slow)
                            // double-tap-to-voice is recognised first instead of the 1st tap firing detail.
#define LONG_PRESS_MS 5000  // hold still this long = a deliberate long-press (create project / open WiFi portal)
// Distance thresholds below come from the ROUND board (466px), scaled by 480/466 (~1.03) — NOT from the
// 720px board this file was otherwise ported from, whose numbers are all ~1.55x too large. A pixel
// threshold is really a statement about how far a finger travels, and this panel is the round board's
// size; inheriting the big board's numbers would make every gesture need half again as much movement.
// Timings are NOT scaled at all; they are human, not geometric.
#define LONG_MOVE_PX  31    // a press that moves more than this is a swipe, not a hold (30 @466)

// One-shot: set when a deliberate long-press completes. Drained by touch_take_longpress(). Detected
// every read (even while the panel is asleep) so it works in cool-standby with the screen off.
static volatile bool s_longpress;
// Single writer (LVGL touch task), lock-free readers. A 32-bit aligned load/store is atomic on ESP32-S3;
// wraparound is harmless because consumers compare generations for equality only.
static volatile uint32_t s_activity_gen;

uint32_t touch_activity_generation(void)
{
    return s_activity_gen;
}

static void longpress_track(bool pressed, uint16_t x, uint16_t y)
{
    static bool prev;
    static uint32_t t0;
    static int16_t sx, sy;
    static bool moved, fired;
    uint32_t now = lv_tick_get();
    if (pressed && !prev) {
        t0 = now; sx = x; sy = y; moved = false; fired = false;
    } else if (pressed) {
        int dx = (int)x - sx, dy = (int)y - sy;
        if (dx * dx + dy * dy > LONG_MOVE_PX * LONG_MOVE_PX) moved = true;
        // Not while a voice/goal capture is active — a 2s goal-hold already owns this press (see touch_read).
        if (!fired && !moved && !ui_voice_is_active() && now - t0 >= LONG_PRESS_MS) { s_longpress = true; fired = true; }
    }
    prev = pressed;
}

bool touch_take_longpress(void)
{
    bool v = s_longpress;
    s_longpress = false;
    return v;
}

// Edge-triggered double-tap detector. Call EVERY read (to track the press edge); returns true once
// on the second of two quick, nearby taps. Shared by both wake (asleep) and sleep (awake).
static bool double_tap(bool pressed, uint16_t x, uint16_t y)
{
    static bool prev;
    static uint32_t last_ms;
    static int16_t lx, ly;
    bool hit = false;
    if (pressed && !prev) {                          // rising edge = a tap
        uint32_t now = lv_tick_get();
        int dx = (int)x - lx, dy = (int)y - ly;
        if (now - last_ms < DOUBLE_TAP_MS && dx * dx + dy * dy < 124 * 124) {   // 80px @466, scaled
            hit = true; last_ms = 0;                 // consumed — a 3rd tap won't re-trigger
        } else {
            last_ms = now; lx = x; ly = y;
        }
    }
    prev = pressed;
    return hit;
}

// Edge-triggered swipe/tap detector. Call EVERY read (awake only). On press-down it snapshots the tile
// position (ui_swipe_begin); on release it classifies the gesture: a mostly-horizontal drag → ui_swipe_end
// (circular wrap); a mostly-vertical drag → ui_swipe_vert (open/close the reader); a short near-still
// press is a TAP → STOP voice if we're recording (voice is gesture-driven: double-tap starts, tap stops).
#define SWIPE_MIN_PX 57    // 55 @466
#define TAP_MAX_MS   700   // a near-still press shorter than this = a tap (not a hold/long-press)
// Home gesture: an upward swipe must START at/below this y (panel is 480 tall) to count as a bottom-edge
// swipe → Overview. Bottom ~14% band; well below where mid-tile "swipe-up = open detail" gestures begin.
#define BOTTOM_EDGE_PX 412
// On the detail reader the ONLY non-scroll vertical gesture is a tight bottom-edge up-swipe → Overview, so it
// uses a much narrower band than the carousel screens: a swipe that STARTS within the bottom ~20px (panel 480).
#define READER_HOME_EDGE_PX 460
// A single tap toggles the detail reader (open on projects / close on the reader), but a double-tap
// starts voice. They're indistinguishable until the double-tap window passes, so DEFER the tap's action
// by DOUBLE_TAP_MS and cancel it if a 2nd tap arrives (that's a start-voice). A tap while RECORDING is
// NOT deferred — it stops immediately (see rec_at_down below).
static bool s_tap_pending;
static uint32_t s_tap_pending_ms;
static uint16_t s_tap_x, s_tap_y;   // where the press landed — ui_tap() needs it to know WHAT was tapped
// Something else already acted on this press (an Overview row jumping to an agent). Without this the
// deferred tap fires afterwards on the page it just navigated TO, so one finger travels two screens.
void ui_tap_cancel(void) { s_tap_pending = false; }
// GOAL gesture: a still hold ≥3s (awake, not already recording) starts a GOAL voice command (long-press).
// It "consumes" the press: cancels the 5s create-project longpress + swallows the rest so it lands as no UI tap.
#define GOAL_HOLD_MS 2000
static bool s_goal_swallow;
// Swallow all input until the finger lifts — set after a wake tap / double-tap-voice / goal-hold so the
// consumed gesture doesn't also drive the UI. File-scope so swipe_track can be gated off while it's set
// (otherwise swipe_track starts mid-gesture on the read after wake and classifies the release as a tap →
// stray "open detail" on the very tap that woke the screen).
static bool s_swallow_until_release;
// This press landed on a real control in the action bar / status band. Swipes from it still count (see
// swipe_track) — only the TAP is withheld, because LVGL is delivering that same press to the button.
static bool s_action_press;
static void swipe_track(bool pressed, uint16_t x, uint16_t y)
{
    static bool prev;
    static int sx, sy, lx, ly;
    static uint32_t t0;
    static bool rec_at_down;   // was a turn recording when THIS press began? (see the tap-to-stop below)
    if (pressed && !prev) {                 // press down
        sx = lx = x; sy = ly = y; t0 = lv_tick_get();
        rec_at_down = ui_voice_is_recording();
        ui_swipe_begin();
    } else if (pressed) {                   // dragging → remember the latest point
        lx = x; ly = y;
    } else if (!pressed && prev) {          // release
        int dx = lx - sx, dy = ly - sy;
        // During a voice turn the overlay owns the screen: ONLY tap-to-stop is allowed — swiping must not
        // switch tiles / open detail / jump home underneath the overlay. So gate every swipe action off while
        // voice is active and fall straight through to the tap branch (which stops the recording).
        bool voice = ui_voice_is_active();
        // The DETAIL READER has its own tight gesture set (the rest is native vertical scroll):
        //   • up-swipe from the bottom ~20px → Overview   • horizontal swipe → back to the agent screen
        // Everything else on the reader (mid-screen vertical drag, taps) is left to LVGL scroll / does nothing.
        // (double-tap = voice and the ≥2s hold = goal are handled in touch_read, independent of this.)
        bool reader = ui_reader_is_open();
        int home_edge = reader ? READER_HOME_EDGE_PX : BOTTOM_EDGE_PX;
        // HOME gesture: an upward swipe that STARTED at the bottom edge → jump to Overview. (y grows downward;
        // the driver already applies the panel mirror, so sy near y_max = the physical bottom.)
        if (!voice && sy >= home_edge && dy < -SWIPE_MIN_PX && abs(dy) > abs(dx))
            ui_home_overview();
        else if (!voice && (dx > SWIPE_MIN_PX || dx < -SWIPE_MIN_PX) && abs(dx) > abs(dy))
            ui_swipe_end(dx > 0 ? 1 : -1);         // reader → back to the agent; carousel screens → wrap next/prev
        else if (!voice && !reader && (dy > SWIPE_MIN_PX || dy < -SWIPE_MIN_PX) && abs(dy) > abs(dx))
            ui_swipe_vert(dy < 0 ? 1 : -1);        // NOT on the reader — there vertical is pure native scroll
        else if (abs(dx) < LONG_MOVE_PX && abs(dy) < LONG_MOVE_PX
                 && lv_tick_elaps(t0) < TAP_MAX_MS) {   // near-still TAP
            // A tap while RECORDING always stops the voice — on EVERY screen, including the reader (this is the
            // only touch way to end a turn started by double-tap there). The deferred open/close tap, however,
            // is disabled on the reader (it has no single-tap action).
            if (rec_at_down) ui_voice_stop();
            else if (!reader && !s_action_press) { s_tap_pending = true; s_tap_pending_ms = t0;
                                                   s_tap_x = sx; s_tap_y = sy; }
        }
        // (a swipe while recording matches none of the above → ignored; only a still tap stops the voice)
    }
    prev = pressed;
}

// LVGL reads the latest touch point. Marshalled by LVGL's own task; reading the
// GT911 over I2C from here is fine (LVGL task holds no conflicting lock).
static void touch_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    static bool activity_prev;
    // `indev` is used: the notification block cancels an in-flight press through it (lv_indev_wait_release).
    if (!s_tp) { data->state = LV_INDEV_STATE_RELEASED; return; }
    uint16_t x = 0, y = 0, strength = 0;
    uint8_t cnt = 0;
    esp_lcd_touch_read_data(s_tp);
    bool pressed = esp_lcd_touch_get_coordinates(s_tp, &x, &y, &strength, &cnt, 1) && cnt > 0;
    if (pressed && !activity_prev) s_activity_gen++;
    activity_prev = pressed;

    // A touch that STARTS on an action-bar button (or a status-band icon) belongs to that LVGL button.
    // Feed `false` to the HOLD recognizers for the whole gesture — otherwise holding the voice pill for 2s
    // would also fire the hidden global Goal gesture, and a quick double-tap on it would fire global voice.
    //
    // SWIPES are deliberately NOT suppressed. The bar spans 604-692 and the home-swipe edge starts at 620,
    // so gating swipes on it would take the "swipe up from the bottom → Overview" gesture away from most
    // of the bottom edge on every agent tile. A swipe releases far from the button, so LVGL fires no click
    // and the two cannot both happen: a tap is a button press, a drag is a gesture.
    static bool action_prev, action_capture;
    if (pressed && !action_prev) {
        action_capture = ui_action_hit(x, y);
        if (action_capture) s_tap_pending = false;
    }
    bool action_touch = action_capture && (pressed || action_prev);
    bool gesture_pressed = pressed && !action_touch;
    s_action_press = action_touch;
    if (!pressed && action_prev) action_capture = false;
    action_prev = pressed;

    bool dbl = double_tap(gesture_pressed, x, y);     // call every read to keep edge tracking valid
    longpress_track(gesture_pressed, x, y);           // detect a deliberate hold (portal trigger in standby)

    // The notification zone OWNS its gestures — like the brightness catcher — so a pull-down or a list
    // scroll can never leak into the voice/detail layer. Capture the whole gesture from press-down when
    // the drawer is already OPEN, or when a press starts in the top pull-zone (ui_notif_pull_zone_px() —
    // narrow on agent tiles so the Mode/Model chips still get taps, full band on Overview/Settings/Machines).
    // While captured:
    // feed LVGL only if the drawer is open (so the list scrolls + rows/background tap); otherwise swallow
    // (a top-zone pull must not drive the projects UI underneath). On release, decide open/close.
    //
    // BACK IS SIDEWAYS, not up. A horizontal swipe leaves the drawer, matching every other secondary
    // screen on this device (the reader, the wifi picker, the model picker all go back on a horizontal
    // swipe). Up stays as a second way out, but only from the top of the list — vertical belongs to
    // SCROLLING now that the column runs the full height, and a gesture that both scrolls and closes
    // is one the finger has to think about.
    {
        static bool ndrag, nprev, nhoriz; static int ndx0, ndxl, ndy0, ndyl;
        bool ncap = false;
        if (pressed && !nprev) {
            // Not on the reader: notifications aren't openable there, and swallowing the top band would break
            // scrolling from the top of the text. The reader owns its whole surface for vertical scroll.
            // `action_capture` means the press landed on a real control (the status-band bell/gear, an
            // Overview voice button). Those must win over the pull-down: the band icons live INSIDE the
            // top zone, so without this test the drawer gesture swallows them and they can never be
            // tapped at all — which is what happened when the icons were added.
            ndrag = !display_is_asleep() && !ui_reader_is_open() && !action_capture
                    && (ui_notif_is_open() || y < ui_notif_pull_zone_px());
            ndx0 = ndxl = x; ndy0 = ndyl = y; nhoriz = false; ncap = ndrag;
        } else if (pressed && ndrag) {
            ndxl = x; ndyl = y; ncap = true;
            // Recognise "back" MID-gesture, not on release. The finger is almost always on a card, and
            // the list only scrolls vertically — so LVGL never cancels the press itself and would fire
            // CLICKED on release, opening whichever agent the swipe happened to start on. Telling the
            // indev to wait for release ends the press with no click, which is what a swipe should do.
            if (ui_notif_is_open() && !nhoriz) {
                int dx = ndxl - ndx0, dy = ndyl - ndy0;
                if (abs(dx) > SWIPE_MIN_PX && abs(dx) > abs(dy)) { nhoriz = true; lv_indev_wait_release(indev); }
            }
        } else if (!pressed && nprev && ndrag) {          // release of a captured gesture
            int dx = ndxl - ndx0, dy = ndyl - ndy0;
            if (ui_notif_is_open()) {
                if (nhoriz || (abs(dx) > SWIPE_MIN_PX && abs(dx) > abs(dy))) ui_notif_close();  // sideways → back
                else if (dy < -SWIPE_MIN_PX) ui_notif_swipe_up();                     // up → close, only at the top
            }
            else if (dy > SWIPE_MIN_PX) ui_notif_open();                              // pull down from top → open
            ndrag = false; nhoriz = false; ncap = true;
        }
        nprev = pressed;
        if (ncap) {
            if (ui_notif_is_open() && pressed) { data->point.x = x; data->point.y = y; data->state = LV_INDEV_STATE_PRESSED; }
            else data->state = LV_INDEV_STATE_RELEASED;   // closed-zone pull → swallow; or released
            return;
        }
    }

    // Swipes + tap-to-stop-voice. Skip while swallowing a consumed gesture (wake / voice / goal) so the
    // release of that gesture isn't misread as a fresh tap.
    if (!display_is_asleep() && !s_swallow_until_release && !s_goal_swallow) swipe_track(pressed, x, y);

    // GOAL: a still hold ≥3s (awake, not already recording) → start a GOAL voice command. Consumes the press
    // (cancel the 5s create-project + swallow the rest so it doesn't land as a UI tap on release).
    {
        static bool gprev; static uint32_t gt0; static int16_t gsx, gsy; static bool gmoved, gfired;
        if (gesture_pressed && !gprev) { gt0 = lv_tick_get(); gsx = x; gsy = y; gmoved = false; gfired = false; }
        else if (gesture_pressed && !gfired) {
            int dx = (int)x - gsx, dy = (int)y - gsy;
            if (dx * dx + dy * dy > LONG_MOVE_PX * LONG_MOVE_PX) gmoved = true;
            if (!gmoved && !display_is_asleep() && !ui_voice_is_active() && lv_tick_elaps(gt0) >= GOAL_HOLD_MS) {
                gfired = true;
                s_longpress = false;   // this hold is a goal, not a create-project
                s_goal_swallow = true; // swallow until the finger lifts (no stray UI tap)
                ui_voice_start_goal();
            }
        }
        gprev = gesture_pressed;
    }

    // Resolve a deferred single tap. Anchored to the PRESS and only fires once the double-tap window has
    // passed — so a double-tap always cancels it first. Extra guard: skip if a turn just started (voice).
    if (dbl) s_tap_pending = false;
    else if (s_tap_pending && lv_tick_elaps(s_tap_pending_ms) >= DOUBLE_TAP_MS) {
        s_tap_pending = false;
        if (!display_is_asleep() && !ui_voice_is_active()) ui_tap(s_tap_x, s_tap_y);
    }

    // After a double-tap starts voice, the finger is usually STILL down. Keep swallowing until it lifts,
    // so the two taps don't also land as UI presses (a stray tile/settings click).
    if (s_swallow_until_release || s_goal_swallow) {
        if (pressed) { data->state = LV_INDEV_STATE_RELEASED; return; }
        s_swallow_until_release = false;
        s_goal_swallow = false;   // finger lifted → goal-hold press fully consumed
    }

    if (display_is_asleep()) {
        // Asleep: a SINGLE tap WAKES the screen (Button A also wakes/sleeps). Wake on press-down and swallow
        // until the finger lifts so the waking tap doesn't fall through as a UI tap / start voice.
        if (pressed) { display_wake(); s_swallow_until_release = true; }
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }

    // During a voice turn the overlay owns the whole screen: never forward the touch to LVGL, so a swipe can't
    // natively scroll the tileview to Settings and a stop-tap can't land on a Wifi/passcode row underneath.
    // tap-to-stop + swipe suppression already ran in swipe_track above (raw coords) — swallow everything else.
    if (ui_voice_is_active()) { data->state = LV_INDEV_STATE_RELEASED; return; }

    // Awake: double-tap STARTS voice (only when fully idle — a live turn keeps audio active and blocks a
    // restart). Stopping is a single tap (swipe_track), so this is start-only.
    if (dbl) {
        if (!ui_voice_is_active()) ui_voice_start();
        s_swallow_until_release = true;              // don't let the 2 taps land as UI presses
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }

    if (pressed) {
        data->point.x = x;
        data->point.y = y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

void touch_init(void)
{
    // Shared I2C master bus (touch + audio codecs live on the same bus).
    i2c_master_bus_handle_t bus = board_i2c_get();
    if (!bus) {
        ESP_LOGW(TAG, "shared i2c bus unavailable — touch disabled");
        return;
    }

    esp_lcd_panel_io_handle_t tp_io = NULL;
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_GT911_CONFIG();
    io_cfg.scl_speed_hz = BSP_I2C_FREQ_HZ;
    if (esp_lcd_new_panel_io_i2c(bus, &io_cfg, &tp_io) != ESP_OK) {
        ESP_LOGW(TAG, "touch panel io failed — touch disabled");
        return;
    }

    esp_lcd_touch_config_t tp_cfg = {
        .x_max = BSP_LCD_H_RES,
        .y_max = BSP_LCD_V_RES,
        .rst_gpio_num = BSP_TOUCH_RST,
        // GPIO_NUM_NC: this board routes the GT911 INT line to test point TP2 only, never to a pin. The
        // driver therefore cannot wait on an interrupt and reads the controller on every poll instead —
        // which is what touch_read() below already does, so nothing above this line changes.
        .int_gpio_num = BSP_TOUCH_INT,
        // Orientation is DELIBERATELY neutral, not copied. The round board needs mirror_x/mirror_y
        // because its CST9217 is mounted 180° to the panel; that is a fact about that board's assembly
        // and says nothing about this one. Establish the true orientation on hardware — drag a finger
        // left and check the UI follows — and set these flags from what you observe.
        .flags = { .swap_xy = 0, .mirror_x = 0, .mirror_y = 0 },
    };
    if (esp_lcd_touch_new_i2c_gt911(tp_io, &tp_cfg, &s_tp) != ESP_OK) {
        ESP_LOGW(TAG, "GT911 init failed — touch disabled");
        s_tp = NULL;
        return;
    }

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, touch_read);
    ESP_LOGI(TAG, "GT911 touch ready (polled — no INT line on this board)");
}
