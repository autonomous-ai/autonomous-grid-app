#include "touch.h"
#include "board_pins.h"
#include "board_i2c.h"
#include "display.h"
#include "ui_screens.h"
#include "panel_client.h"   // ui_swipe_begin/end for the circular edge-swipe
#include "driver/i2c_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_cst9217.h"
#include "esp_log.h"
#include "lvgl.h"
#include <stdlib.h>

static const char *TAG = "touch";
static esp_lcd_touch_handle_t s_tp;

#define DOUBLE_TAP_MS 500   // two taps within this window (and close in position) = a double-tap. Also the
                            // delay before a single tap opens the detail reader ON THE SCREENS WHERE A
                            // DOUBLE-TAP MEANS SOMETHING — see voice_gesture_here().
#define LONG_PRESS_MS 5000  // hold still this long = a deliberate long-press (create project / open WiFi portal)
#define LONG_MOVE_PX  30    // a press that moves more than this is a swipe, not a hold

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

// Edge-triggered double-tap detector. Call EVERY read (to track the press edge); returns true once
// on the second of two quick, nearby taps.
static bool double_tap(bool pressed, uint16_t x, uint16_t y)
{
    static bool prev;
    static uint32_t last_ms;
    static int16_t lx, ly;
    bool hit = false;
    if (pressed && !prev) {                          // rising edge = a tap
        uint32_t now = lv_tick_get();
        int dx = (int)x - lx, dy = (int)y - ly;
        if (now - last_ms < DOUBLE_TAP_MS && dx * dx + dy * dy < 80 * 80) {
            hit = true; last_ms = 0;                 // consumed — a 3rd tap won't re-trigger
        } else {
            last_ms = now; lx = x; ly = y;
        }
    }
    prev = pressed;
    return hit;
}

// Where a double-tap starts a voice turn: on an agent tile, and inside its detail reader. NOT on the
// Overview or Settings — the Overview has its own labelled Voice / Goal / Loop row, and Settings has
// nothing to talk to.
//
// ui_active_tile_id() answers both at once: it is "" on the Overview and on Settings, and the reader
// belongs to the tile underneath it, so a non-empty id IS "there is an agent here to speak to".
static bool voice_gesture_here(void)
{
    return ui_active_tile_id()[0] != '\0';
}

bool touch_take_longpress(void)
{
    bool v = s_longpress;
    s_longpress = false;
    return v;
}

// Edge-triggered swipe/tap detector. Call EVERY read (awake only). On press-down it snapshots the tile
// position (ui_swipe_begin); on release it classifies the gesture: a mostly-horizontal drag → ui_swipe_end
// (circular wrap); a mostly-vertical drag → scrolls the window (panel_client_send_scroll); a short near-still
// press is a TAP → STOP voice if we're recording, else open the detail reader.
#define SWIPE_MIN_PX 55
#define TAP_MAX_MS   700   // a near-still press shorter than this = a tap (not a hold/long-press)
// Home gesture: an upward swipe must START at/below this y (panel is 466 tall) to count as a bottom-edge
// swipe → Overview. Bottom ~14% band; well below where mid-tile "swipe-up = open detail" gestures begin.
#define BOTTOM_EDGE_PX 400
// On the detail reader the ONLY non-scroll vertical gesture is a tight bottom-edge up-swipe → Overview, so it
// uses a much narrower band than the carousel screens: a swipe that STARTS within the bottom ~20px (panel 466).
#define READER_HOME_EDGE_PX 446
// DOUBLE-TAP STARTS VOICE, on an agent tile and in its detail reader only (voice_gesture_here()). It was
// removed screen-wide on 2026-08-20 — every screen has a visible Voice button, and a hidden gesture that
// duplicates a button is a way to start a recording by accident — and put back the same day for these two
// screens, where reaching a 40px mark is worse than tapping twice anywhere. The Overview keeps its
// labelled row and nothing else; the ≥2s hold-for-Goal stayed gone, since Goal has a button of its own.
//
// The COST is the deferral below, and it is worth stating plainly: a tap and the first half of a
// double-tap are the same event, so wherever a double-tap means something the tap's action has to wait out
// DOUBLE_TAP_MS before it can be trusted. That is why the deferral is scoped to exactly those screens
// rather than applied everywhere — on the Overview a tap acts at once, and on the reader there is no
// single-tap action to race, so the only screen that pays is the agent tile.
//
// Swallow all input until the finger lifts — set after a wake tap or a double-tap-voice so the consumed
// gesture doesn't also drive the UI. File-scope so swipe_track can be gated off while it's set
// (otherwise swipe_track starts mid-gesture on the read after wake and classifies the release as a tap →
// stray "open detail" on the very tap that woke the screen).
static bool s_swallow_until_release;
// A tap whose action is held back until the double-tap window has passed, cancelled if a 2nd tap arrives.
// Anchored to the PRESS, so the wait is the window and not the window plus however long the finger stayed
// down. Only ever set where voice_gesture_here() — see the note above.
static bool s_tap_pending;
static uint32_t s_tap_pending_ms;
// Touchpad reporting: pixels travelled since the last frame went out, when that was, and how fast the
// finger was moving while it did.
#define SCROLL_MIN_PX   8
#define SCROLL_EVERY_MS 50
// Ceiling on the reported speed, px/s. A single jittery sample across a 4ms window reads as thousands of
// pixels a second; without a lid it would land in the window as a fling to the far end of the transcript.
// ~6000 is well past anything a hand does on a 466px screen and still finite.
#define SCROLL_V_MAX    6000
static int      s_scroll_acc;
static uint32_t s_scroll_at;
static int      s_scroll_v;      // smoothed speed, device px/s, signed like the travel
static bool     s_scroll_live;   // is THIS stroke being reported? decided once, at press-down

// Fold one reporting window into the smoothed speed.
//
// Measured here and not on the far side because this is the only place the hand's speed exists: by the
// time a frame has crossed the cable, been queued, and been decoded, the interval between arrivals says
// more about the link than about the finger.
//
// The window's own length is what makes a resting finger decay to nothing — a window with no travel in it
// is a real measurement of zero, so a hand that stops before lifting is not thrown.
static void scroll_measure(int px, uint32_t ms)
{
    if (!ms) return;
    int inst = px * 1000 / (int)ms;
    if (inst >  SCROLL_V_MAX) inst =  SCROLL_V_MAX;
    if (inst < -SCROLL_V_MAX) inst = -SCROLL_V_MAX;
    // Weighted 3:2 toward the newest window: enough smoothing that one bad sample can't define a fling,
    // little enough that the flick at the END of a stroke is what gets measured — which is the whole of
    // what a person means by "how fast I swiped".
    s_scroll_v = (inst * 3 + s_scroll_v * 2) / 5;
}
static void swipe_track(bool pressed, uint16_t x, uint16_t y)
{
    static bool prev;
    static int sx, sy, lx, ly;
    static uint32_t t0;
    static bool rec_at_down;   // was a turn recording when THIS press began? (see the tap-to-stop below)
    if (pressed && !prev) {                 // press down
        sx = lx = x; sy = ly = y; t0 = lv_tick_get();
        s_scroll_acc = 0;
        s_scroll_at = t0;
        s_scroll_v = 0;
        // Decided once, here, for the whole stroke — the window opens a drag on this frame and must be
        // told when it ends, so eligibility cannot be re-judged report by report.
        //
        // NOT for a stroke that began at the bottom edge: that one is the home swipe, and scrolling the
        // window on the way to leaving the screen is not what the hand meant. Nor during voice — the
        // overlay owns the screen. (A gesture the drawer captured never reaches here at all.)
        s_scroll_live = !ui_voice_is_active() && sy < BOTTOM_EDGE_PX;
        if (s_scroll_live) panel_client_send_scroll(PANEL_SCROLL_DOWN, 0, 0);
        rec_at_down = ui_voice_is_recording();
        ui_swipe_begin();
    } else if (pressed) {                   // dragging → remember the latest point, and report the travel
        // THE PANEL AS A TOUCHPAD. Reported while the finger is still down, in pieces, because that is
        // what makes it feel like one: waiting for the release would move the window once, after the
        // hand had already stopped.
        //
        // Throttled here rather than on the far side — this is where the touch stream is. The driver
        // delivers 60-100 samples a second and a frame each would be pointless traffic; ~8px or ~50ms,
        // whichever comes first, is under what a hand notices and is ~20 small frames a second at most.
        //
        // NOT sent while the notification drawer has captured the gesture (it owns the whole stroke
        // then), nor during voice (the overlay owns the screen), nor for a stroke that began at the
        // bottom edge — that one is the home swipe, and scrolling the window on the way to leaving the
        // screen is not what the hand meant.
        s_scroll_acc += y - ly;
        // Voice came up mid-stroke (a button under the finger): end the drag rather than abandon it, or
        // the window sits holding a gesture that is never coming back.
        if (s_scroll_live && ui_voice_is_active()) {
            panel_client_send_scroll(PANEL_SCROLL_UP, 0, 0);
            s_scroll_live = false;
        }
        if (s_scroll_live && (abs(s_scroll_acc) >= SCROLL_MIN_PX
                              || lv_tick_elaps(s_scroll_at) >= SCROLL_EVERY_MS)) {
            scroll_measure(s_scroll_acc, lv_tick_elaps(s_scroll_at));
            if (s_scroll_acc) panel_client_send_scroll(PANEL_SCROLL_MOVE, s_scroll_acc, 0);
            s_scroll_acc = 0;
            s_scroll_at = lv_tick_get();
        }
        lx = x; ly = y;
    } else if (!pressed && prev) {          // release
        // Close the stroke FIRST, before any gesture is classified: the window is holding a drag and the
        // speed it left at is the one thing that turns a swipe into a throw. Whatever travel hadn't yet
        // reached the reporting threshold rides along — it is the last few pixels of the stroke, which is
        // exactly where a hand is aiming.
        if (s_scroll_live) {
            scroll_measure(s_scroll_acc, lv_tick_elaps(s_scroll_at));
            panel_client_send_scroll(PANEL_SCROLL_UP, s_scroll_acc, s_scroll_v);
            s_scroll_live = false;
        }
        int dx = lx - sx, dy = ly - sy;
        // During a voice turn the overlay owns the screen: ONLY tap-to-stop is allowed — swiping must not
        // switch tiles / open detail / jump home underneath the overlay. So gate every swipe action off while
        // voice is active and fall straight through to the tap branch (which stops the recording).
        bool voice = ui_voice_is_active();
        // The DETAIL READER has its own tight gesture set (the rest is native vertical scroll):
        //   • up-swipe from the bottom ~20px → Overview   • horizontal swipe → back to the agent screen
        // Everything else on the reader (mid-screen vertical drag, taps) is left to LVGL scroll / does nothing.
        bool reader = ui_reader_is_open();
        int home_edge = reader ? READER_HOME_EDGE_PX : BOTTOM_EDGE_PX;
        // HOME gesture: an upward swipe that STARTED at the bottom edge → jump to Overview. (y grows downward;
        // the driver already applies the panel mirror, so sy near y_max = the physical bottom.)
        if (!voice && sy >= home_edge && dy < -SWIPE_MIN_PX && abs(dy) > abs(dx))
            ui_home_overview();
        else if (!voice && (dx > SWIPE_MIN_PX || dx < -SWIPE_MIN_PX) && abs(dx) > abs(dy))
            ui_swipe_end(dx > 0 ? 1 : -1);         // reader → back to the agent; carousel screens → wrap next/prev
        // A VERTICAL DRAG NO LONGER OPENS THE DETAIL SCREEN. It scrolls the window (above), and one
        // gesture cannot mean two things — every scroll would have ended by opening a screen the user
        // did not ask for. The detail screen still opens with a tap, which is the route ui_tap has
        // always offered.
        else if (abs(dx) < LONG_MOVE_PX && abs(dy) < LONG_MOVE_PX
                 && lv_tick_elaps(t0) < TAP_MAX_MS) {   // near-still TAP
            // A tap while RECORDING always stops the voice — on EVERY screen, including the reader, where
            // the overlay is all there is. That one is never deferred: stopping must feel immediate, and
            // a second tap during a recording means nothing anyway.
            //
            // Otherwise it opens the detail screen — held back only on the screens where a double-tap is
            // also a gesture, because there the two are the same event until the window passes. The reader
            // has no single-tap action to hold back at all.
            if (rec_at_down) ui_voice_stop();
            else if (!reader && !voice) {
                if (voice_gesture_here()) { s_tap_pending = true; s_tap_pending_ms = t0; }
                else ui_tap();
            }
        }
        // (a swipe while recording matches none of the above → ignored; only a still tap stops the voice)
    }
    prev = pressed;
}

// LVGL reads the latest touch point. Marshalled by LVGL's own task; reading the
// CST9217 over I2C from here is fine (LVGL task holds no conflicting lock).
static void touch_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    static bool activity_prev;
    (void)indev;
    if (!s_tp) { data->state = LV_INDEV_STATE_RELEASED; return; }
    uint16_t x = 0, y = 0, strength = 0;
    uint8_t cnt = 0;
    esp_lcd_touch_read_data(s_tp);
    bool pressed = esp_lcd_touch_get_coordinates(s_tp, &x, &y, &strength, &cnt, 1) && cnt > 0;
    if (pressed && !activity_prev) s_activity_gen++;
    activity_prev = pressed;

    // A touch that STARTS on one of Overview's two round voice actions belongs to that LVGL button until
    // release. Feed `false` to the screen-wide recognizers for the whole gesture, but keep the real pointer
    // state for LVGL below. Without it a press on one of those buttons is ALSO a near-still tap to
    // swipe_track, which would open the detail reader on the very release that starts the recording — two
    // things from one touch. A drag can still leave the button and scroll the carousel through LVGL.
    static bool action_prev, action_capture;
    if (pressed && !action_prev) {
        action_capture = ui_action_row_hit(x, y);
        if (action_capture) s_tap_pending = false;
    }
    bool action_touch = action_capture && (pressed || action_prev);
    bool gesture_pressed = pressed && !action_touch;
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
    {
        static bool ndrag, nprev; static int ndy0, ndyl;
        bool ncap = false;
        if (pressed && !nprev) {
            // Not on the reader: notifications aren't openable there, and swallowing the top band would break
            // scrolling from the top of the text. The reader owns its whole surface for vertical scroll.
            ndrag = !display_is_asleep() && !ui_reader_is_open() && (ui_notif_is_open() || y < ui_notif_pull_zone_px());
            ndy0 = ndyl = y; ncap = ndrag;
        } else if (pressed && ndrag) {
            ndyl = y; ncap = true;
        } else if (!pressed && nprev && ndrag) {          // release of a captured gesture
            int d = ndyl - ndy0;
            if (ui_notif_is_open()) { if (d < -SWIPE_MIN_PX) ui_notif_swipe_up(); }  // up → close (only if list at top)
            else if (d > SWIPE_MIN_PX) ui_notif_open();                              // pull down from top → open
            ndrag = false; ncap = true;
        }
        nprev = pressed;
        if (ncap) {
            if (ui_notif_is_open() && pressed) { data->point.x = x; data->point.y = y; data->state = LV_INDEV_STATE_PRESSED; }
            else data->state = LV_INDEV_STATE_RELEASED;   // closed-zone pull → swallow; or released
            return;
        }
    }

    // Swipes + tap-to-stop-voice. Skip while swallowing a consumed gesture (the tap that woke the screen)
    // so the release of that gesture isn't misread as a fresh tap.
    if (!display_is_asleep() && !s_swallow_until_release) swipe_track(gesture_pressed, x, y);

    // Resolve a deferred single tap. Anchored to the PRESS and only fires once the double-tap window has
    // passed — so a double-tap always cancels it first. Extra guard: skip if a turn just started (voice).
    if (dbl) s_tap_pending = false;
    else if (s_tap_pending && lv_tick_elaps(s_tap_pending_ms) >= DOUBLE_TAP_MS) {
        s_tap_pending = false;
        if (!display_is_asleep() && !ui_voice_is_active()) ui_tap();
    }

    // A consumed gesture keeps being swallowed until the finger lifts, so it doesn't also land as a UI
    // press underneath.
    if (s_swallow_until_release) {
        if (pressed) { data->state = LV_INDEV_STATE_RELEASED; return; }
        s_swallow_until_release = false;
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

    // Awake: double-tap STARTS voice, on the two screens that have an agent behind them. Start-only —
    // stopping is a single tap (swipe_track). A live turn keeps audio active and blocks a restart.
    //
    // Swallowed ONLY when it actually started something: on the Overview and in Settings a double-tap is
    // two ordinary taps, and eating them would break double-tapping a row.
    if (dbl && voice_gesture_here() && !ui_voice_is_active()) {
        ui_voice_start();
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
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_CST9217_CONFIG();
    io_cfg.scl_speed_hz = BSP_I2C_FREQ_HZ;
    if (esp_lcd_new_panel_io_i2c(bus, &io_cfg, &tp_io) != ESP_OK) {
        ESP_LOGW(TAG, "touch panel io failed — touch disabled");
        return;
    }

    esp_lcd_touch_config_t tp_cfg = {
        .x_max = 466,
        .y_max = 466,
        .rst_gpio_num = BSP_TOUCH_RST,
        .int_gpio_num = BSP_TOUCH_INT,
        // The CST9217 is mounted 180° relative to the CO5300 on this board, so BOTH axes are
        // reversed vs the display (horizontal swipe and vertical scroll/taps). Mirror X and Y.
        .flags = { .swap_xy = 0, .mirror_x = 1, .mirror_y = 1 },
    };
    if (esp_lcd_touch_new_i2c_cst9217(tp_io, &tp_cfg, &s_tp) != ESP_OK) {
        ESP_LOGW(TAG, "CST9217 init failed — touch disabled");
        s_tp = NULL;
        return;
    }

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, touch_read);
    ESP_LOGI(TAG, "CST9217 touch ready");
}
