// Bring-up tool: dump what is actually on the panel, as an image, over the LINK.
//
// This is the reference firmware's main/ui_screenshot.c with one thing changed and one thing rewritten.
//
// CHANGED — where it goes. That firmware prints to the console, because its console is on the same USB
// port everything else uses. Here the console is on the OTHER port (the CH343 bridge, 115200) and the
// protocol is on the native one, so a console shot would arrive at a tenth of the speed down a cable
// nobody has open. It goes out as `shot.begin` / `shot.row` / `shot.end` instead — messages grid-app has
// no case for, which protocol.md §2 requires it to ignore and count, and which scripts on the protocol
// port can read.
//
// REWRITTEN — the tour. Its version walks nineteen screens, most of which this firmware does not have.
//
// WHY THIS EXISTS. Reviewing screens by asking a human "does this look right" is the slow path, and it
// is the one that has already cost this project three wrong answers. This panel is RGB, which means the
// frame buffer IS the displayed image — there is no separate copy inside the panel to go stale — so
// reading it back is an exact picture of the screen with nobody looking at the device.
//
// FORMAT. Downscaled by `div` (2 by default, so a shot is ~150 KB of base64), one message per source
// row. The row INDEX travels with the row: a lost or split line would otherwise shift the whole rest of
// the image up by one, which is exactly what happened the first time it was tried.
#include "ui_screenshot.h"
#include "board_pins.h"
#include "display.h"
#include "ui_screens.h"
#include "panel_client.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static const char *TAG = "shot";

// The panel's frame buffer, from ui/display.c. Declared here rather than in display.h so that removing
// this tool does not require touching the display contract.
extern void *display_framebuffer(void);

// Default 2x downscale keeps a shot near 150KB of base64 and is enough to judge composition. Spot
// checks that need to see whether two labels actually touch use div=1 — four times the bytes, so it is
// a per-shot choice rather than the default.
#define SHOT_DIV 2
#define SHOT_W_MAX BSP_LCD_H_RES

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// One row of base64: 240 px * 2 B = 480 B in, 640 chars out. Row-at-a-time keeps the stack flat (no
// whole-image buffer) and gives the host something to resynchronise on.
static void emit_row_b64(int y, const uint16_t *row, int w)
{
    static char out[SHOT_W_MAX * 2 * 4 / 3 + 8];
    const uint8_t *p = (const uint8_t *)row;
    size_t n = (size_t)w * 2, o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16;
        if (i + 1 < n) v |= (uint32_t)p[i + 1] << 8;
        if (i + 2 < n) v |= p[i + 2];
        out[o++] = B64[(v >> 18) & 63];
        out[o++] = B64[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? B64[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? B64[v & 63] : '=';
    }
    out[o] = 0;
    panel_client_shot_row(y, out);
}

void ui_screenshot_ex(const char *name, int div)
{
    if (div < 1) div = 1;
    const int w = BSP_LCD_H_RES / div, h = BSP_LCD_V_RES / div;
    const uint16_t *fb = (const uint16_t *)display_framebuffer();
    if (!fb) { ESP_LOGE(TAG, "no frame buffer"); return; }

    // Let LVGL finish whatever it was drawing, so the shot is a settled frame rather than a half-painted
    // one. The refresh timer runs on the LVGL task; a short wait is simpler than hooking its completion.
    vTaskDelay(pdMS_TO_TICKS(250));

    panel_client_shot_begin(name, w, h);
    static uint16_t row[SHOT_W_MAX];
    for (int y = 0; y < h; y++) {
        const uint16_t *src = fb + (size_t)(y * div) * BSP_LCD_H_RES;
        for (int x = 0; x < w; x++) row[x] = src[x * div];   // nearest-neighbour: no colour maths
        emit_row_b64(y, row, w);
    }
    panel_client_shot_end(name);
}

void ui_screenshot(const char *name) { ui_screenshot_ex(name, SHOT_DIV); }

// ── The tour ─────────────────────────────────────────────────────────────────────────────────────────
//
// Every surface this firmware has, shot once. The carousel pages need CONTENT and the device has none
// until grid-app answers, so seed a plausible machine and three projects through the same public API the
// link handlers use. Fake data on a real layout is exactly what a layout review wants — and it is
// reproducible, which a live desktop is not.
static void seed_fake_content(void)
{
    ui_set_machine_name("duy-macbook");
    ui_set_connected(true);

    ui_project_set_name("p1", "harness backend");
    ui_project_set_engine("p1", "claude");
    ui_project_set_selected_model("p1", "opus");
    ui_project_set_name("p2", "esp32 square s3");
    ui_project_set_engine("p2", "codex");
    ui_project_set_name("p3", "web");
    ui_project_set_engine("p3", "cursor");

    // A recap long enough to exercise wrapping and the preview clip, in Vietnamese so the diacritics
    // (the tallest glyphs this font set has to place) are part of the review rather than an afterthought.
    ui_project_emit("p1", "done",
                    "Đã sửa xong lỗi backlight và bảng init của panel ST7701. Màn hình đã lên và quét ổn "
                    "định ở 42 Hz. Còn lại phần rà soát bố cục cho đúng 480×480 và kiểm tra chiều xoay "
                    "của cảm ứng.", NULL);
    ui_project_emit("p2", "processing", "Đang dựng lại bộ font", NULL);
}

void ui_screenshot_tour(void)
{
    ESP_LOGW(TAG, "=== UI TOUR: shooting every screen ===");

    ui_show_connecting("Waiting for Grid\xE2\x80\xA6");   ui_screenshot("connecting");
    ui_show_error("Voice failed", "Grid could not transcribe that."); ui_screenshot("error");

    seed_fake_content();
    ui_show_projects();
    ui_home_overview();                                   ui_screenshot_ex("overview", 1);

    // Move between tiles by FOCUSING a project rather than by faking a swipe: ui_swipe_end() does not
    // scroll the carousel (the container owns that natively), which is why an earlier tour shot the same
    // page six times.
    ui_focus_project("p1");  vTaskDelay(pdMS_TO_TICKS(400));  ui_screenshot_ex("tile_recap", 1);
    ui_focus_project("p2");  vTaskDelay(pdMS_TO_TICKS(400));  ui_screenshot_ex("tile_working", 1);
    ui_focus_project("p3");  vTaskDelay(pdMS_TO_TICKS(400));  ui_screenshot("tile_empty");

    ui_home_overview();  vTaskDelay(pdMS_TO_TICKS(300));
    ui_notif_open();                                      ui_screenshot_ex("notif_drawer", 1);
    ui_notif_close();

    // The one surface this tour cannot reach: voice_start_impl() refuses while the link is down, which
    // it is on a bench device, so the overlay has to be reviewed with grid-app actually attached.
    ESP_LOGW(TAG, "=== UI TOUR done ===");
}
