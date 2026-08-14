// Display bring-up: ST7701 over 16-bit RGB parallel, 480x480.
//
// LIFTED, nearly verbatim, from autonomous-code/apps/esp32-square-s3 — the firmware that already lights
// this exact board. Every measurement and every "do not clean this up" below was paid for there and none
// of it was re-derived here. What was removed on the way in: the OTA boot mode's cut-down init, the
// frame-buffer grab used by that repo's screenshot tool, and the sleep/wake power hook its screen-lock
// needed. Nothing else changed, deliberately — a panel that does not come up is indistinguishable from
// a panel that came up before someone tidied this file.
//
// Comments below that compare against "the round board" or "the P4 board" refer to that reference
// firmware's siblings. They are kept because they say WHY a value is what it is, which is the only
// defence against someone changing it back.
//
// Five things are specific to an RGB panel and worth knowing before touching anything here:
//
//  1. THE PANEL READS PSRAM FOREVER. There is no "send a frame" step: the LCD peripheral streams the
//     frame buffer out continuously, ~24 MB/s at 12 MHz pclk. Every other PSRAM consumer (LVGL pool,
//     the 2 MB voice buffer, TLS) shares that bandwidth. It is the first suspect for any "everything
//     got slower" report.
//  2. NO BOUNCE BUFFERS, AND THE CACHE. The DMA reads the frame buffer straight out of PSRAM, matching
//     Waveshare's own working demo. IDF's docs recommend bounce buffers for bandwidth headroom, but in
//     that mode the LCD cannot run while the external cache is disabled — which is what an NVS write or
//     an OTA install does. CONFIG_SPIRAM_XIP_FROM_PSRAM (see sdkconfig.defaults) keeps the PSRAM cache
//     live across SPI1 flash writes, which is why this board can hold an OTA progress bar on screen
//     while flashing where the P4 board has to black the screen out (see ota.c on both boards).
//  3. THE INIT SEQUENCE DOES NOT TRAVEL ON THESE WIRES. The 16 data lines carry pixels only; the
//     ST7701's registers are written over a 3-wire SPI *bit-banged on the IO expander*. So the expander
//     must be alive before the panel, and the I2C bus before that.
//  4. NO 2-PIXEL ROUNDING. The CO5300 addresses pixels in 2px units and needed an LVGL area rounder.
//     An RGB panel takes arbitrary rectangles; the rounder is absent on purpose, not by omission.
//  5. PIXEL BYTE ORDER. The round board renders LV_COLOR_FORMAT_RGB565_SWAPPED to feed the CO5300
//     without a per-pixel swap. This panel wants NATIVE RGB565. Getting it wrong does not fail to
//     build — it renders in wrong colours (red comes out cyan-ish).
#include "display.h"
#include <stdlib.h>
#include "touch.h"
#include "board_pins.h"
#include "board_i2c.h"
#include "io_expander.h"
#include "ram_telemetry.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_io_additions.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_lcd_st7701.h"
#include "driver/gpio.h"
// No driver/ledc.h. The backlight pad is an ENABLE, not a dimmer — LEDC at 5 kHz produced no light at
// any duty in either polarity. See the measurements at BL_ON_LEVEL below.
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "display";

// ST7701 power-on / gamma / gate-driver sequence, transcribed from Waveshare's ARDUINO demo for this
// board (st7701_type1_init_operations in GFX_Library_for_Arduino) — the only sequence anyone has been
// seen to light this panel with.
//
// It is NOT the table in Waveshare's own ESP-IDF BSP, which this file used first and which leaves the
// panel dark. Diffing the two is the whole story of that bring-up:
//
//   * the BSP NEVER SELECTS PAGE 0x13, so it never writes 0xE5 = 0xE4 there. That page carries VAP/VAN —
//     the panel's analogue supply trim. Skip it and the panel initialises without a single error and
//     drives nothing.
//   * the BSP sets 0x3A = 0x66. The valid values are 0x50 (RGB565), 0x60 (RGB666) and 0x70 (RGB888);
//     0x66 is none of them.
//   * the BSP issues SLEEP OUT (0x11) FIRST, before any configuration. Here it comes last, after every
//     page is written, followed by 120ms and then DISPLAY ON — which is the order the panel's own
//     datasheet flow uses.
//   * three analogue values differ: 0xC2 (0x31,0x05 vs 0x21,0x08), page-1 0xB1 VCOM (0x32 vs 0x30) and
//     page-1 0xB2 VGH (0x07 vs 0x87).
//
// Do not "clean this up": the 0xFF rows are BANK SELECTS, so a reordered or dropped line silently
// programs a different register than it appears to.
static const st7701_lcd_init_cmd_t s_st7701_init_cmds[] = {
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x10}, 5, 0},   // page 0x10
    {0xC0, (uint8_t[]){0x3B, 0x00}, 2, 0},
    {0xC1, (uint8_t[]){0x0D, 0x02}, 2, 0},
    {0xC2, (uint8_t[]){0x31, 0x05}, 2, 0},
    {0xCD, (uint8_t[]){0x08}, 1, 0},
    {0xB0, (uint8_t[]){0x00, 0x11, 0x18, 0x0E, 0x11, 0x06, 0x07, 0x08, 0x07, 0x22, 0x04, 0x12, 0x0F, 0xAA, 0x31, 0x18}, 16, 0},   // +gamma
    {0xB1, (uint8_t[]){0x00, 0x11, 0x19, 0x0E, 0x12, 0x07, 0x08, 0x08, 0x08, 0x22, 0x04, 0x11, 0x11, 0xA9, 0x32, 0x18}, 16, 0},   // -gamma
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x11}, 5, 0},   // page 0x11
    {0xB0, (uint8_t[]){0x60}, 1, 0},   // Vop = 4.7375V
    {0xB1, (uint8_t[]){0x32}, 1, 0},   // VCOM
    {0xB2, (uint8_t[]){0x07}, 1, 0},   // VGH = 15V
    {0xB3, (uint8_t[]){0x80}, 1, 0},
    {0xB5, (uint8_t[]){0x49}, 1, 0},   // VGL = -10.17V
    {0xB7, (uint8_t[]){0x85}, 1, 0},
    {0xB8, (uint8_t[]){0x21}, 1, 0},   // AVDD = 6.6V, AVCL = -4.6V
    {0xC1, (uint8_t[]){0x78}, 1, 0},
    {0xC2, (uint8_t[]){0x78}, 1, 20},
    {0xE0, (uint8_t[]){0x00, 0x1B, 0x02}, 3, 0},
    {0xE1, (uint8_t[]){0x08, 0xA0, 0x00, 0x00, 0x07, 0xA0, 0x00, 0x00, 0x00, 0x44, 0x44}, 11, 0},
    {0xE2, (uint8_t[]){0x11, 0x11, 0x44, 0x44, 0xED, 0xA0, 0x00, 0x00, 0xEC, 0xA0, 0x00, 0x00}, 12, 0},
    {0xE3, (uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0},
    {0xE4, (uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE5, (uint8_t[]){0x0A, 0xE9, 0xD8, 0xA0, 0x0C, 0xEB, 0xD8, 0xA0, 0x0E, 0xED, 0xD8, 0xA0, 0x10, 0xEF, 0xD8, 0xA0}, 16, 0},
    {0xE6, (uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0},
    {0xE7, (uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE8, (uint8_t[]){0x09, 0xE8, 0xD8, 0xA0, 0x0B, 0xEA, 0xD8, 0xA0, 0x0D, 0xEC, 0xD8, 0xA0, 0x0F, 0xEE, 0xD8, 0xA0}, 16, 0},
    {0xEB, (uint8_t[]){0x02, 0x00, 0xE4, 0xE4, 0x88, 0x00, 0x40}, 7, 0},
    {0xEC, (uint8_t[]){0x3C, 0x00}, 2, 0},
    {0xED, (uint8_t[]){0xAB, 0x89, 0x76, 0x54, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x20, 0x45, 0x67, 0x98, 0xBA}, 16, 0},
    // VAP & VAN — the page the BSP never selects. This is the block whose absence kept the panel dark.
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x13}, 5, 0},   // page 0x13
    {0xE5, (uint8_t[]){0xE4}, 1, 0},
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x00}, 5, 0},   // back to the command page
    {0x21, NULL, 0, 0},                // display inversion ON = IPS (0x20 would be a normally-white panel)
    {0x3A, (uint8_t[]){0x60}, 1, 0},   // RGB666. 0x50 = RGB565, 0x70 = RGB888; the BSP's 0x66 is not a value.
    {0x11, NULL, 0, 120},              // sleep out — LAST, after every page is configured
    {0x29, NULL, 0, 0},                // display on
};

static esp_lcd_panel_handle_t s_panel;
static lv_display_t *s_disp;
static SemaphoreHandle_t s_lvgl_mutex;
static bool s_asleep;
static void *s_lvgl_psram_pool;
static uint8_t s_bl_level = 0xFF;   // last level the user asked for; sleep goes dark without forgetting it
static bool s_bl_ready;

// Turn the panel off after this long without a touch.
#define IDLE_MS 300000                  // 5 minutes

// LVGL draw buffers in internal DMA RAM. HALF the round board's slice (V_RES/24 rather than V_RES/16):
// this board also has to find internal RAM for two bounce buffers, which the round board does not have
// at all, and internal RAM — not PSRAM — is the scarce thing on both.
#define DRAW_LINES   (BSP_LCD_V_RES / 24)
#define BYTES_PER_PX (BSP_LCD_BIT_PER_PIXEL / 8)   // RGB565 -> 2
// Bounce buffer height in LINES. 20 is Waveshare's default. Bigger = more internal RAM, more robust
// against PSRAM bandwidth spikes; smaller = the ISR runs more often. Two of these are allocated.
#define BOUNCE_LINES 20
static uint8_t *s_buf1;
static uint8_t *s_buf2;

// VSYNC counter — hard evidence that the RGB timing engine is running. Every other signal we have is an
// API return code, and those stay ESP_OK whether or not a single pixel clock ever leaves the chip.
static volatile uint32_t s_vsync_count;
static bool on_vsync(esp_lcd_panel_handle_t p, const esp_lcd_rgb_panel_event_data_t *e, void *ctx)
{
    s_vsync_count++;
    return false;
}
uint32_t display_vsync_count(void) { return s_vsync_count; }

// ── Backlight: an ENABLE pin, ACTIVE-LOW. Not a PWM dimmer. ─────────────────────────────────────────
// Every word of that was established on the board, because the BSP is wrong about this pad and its own
// brightness function contradicts itself. The evidence, in the order it arrived:
//
//   1. Driving GPIO4 as a plain output, alternating HIGH 4s / LOW 4s, makes the panel blink. So the pad
//      is the backlight and the panel does light.
//   2. Holding it plain-HIGH for six seconds with a white frame in the buffer leaves the panel black.
//      So HIGH is OFF, and by elimination LOW is ON.
//   3. LEDC at 5 kHz produced NO light at any duty, in either polarity — tried both ways round before
//      (1) and (2) narrowed it down. A dimming input would have glowed at 60%; an enable input driven by
//      a square wave does not. So this pad gates a boost converter rather than modulating it.
//
// Hence: plain GPIO, steady level, and "brightness" is on or off. Perceived dimming goes back to the
// round board's method — a black overlay on lv_layer_top faded by ui_set_brightness — which is why that
// function no longer forces the overlay transparent.
//
// If a future board revision does dim in hardware, this is the one place to change, and the test is the
// one above: sweep the pad, watch the panel.
#define BL_ON_LEVEL  0   // active-low
#define BL_OFF_LEVEL 1

// Hold the backlight dark before app_main runs.
//
// A CPU reset returns every GPIO to floating input, and on this active-low pad an undriven pin can read
// as the ON state — lighting whatever the panel happens to be scanning while nothing feeds it. That is a
// coloured flash on every reboot, and the setup flow reboots deliberately (see enter_portal).
static void __attribute__((constructor)) backlight_off_early(void)
{
    gpio_config_t off = { .pin_bit_mask = 1ULL << BSP_LCD_BL_PWM, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&off);
    gpio_set_level(BSP_LCD_BL_PWM, BL_OFF_LEVEL);
}

static void backlight_init(void)
{
    gpio_config_t io = { .pin_bit_mask = 1ULL << BSP_LCD_BL_PWM, .mode = GPIO_MODE_OUTPUT };
    ESP_ERROR_CHECK(gpio_config(&io));
    gpio_set_level(BSP_LCD_BL_PWM, BL_OFF_LEVEL);
    s_bl_ready = true;
}

// Raw apply. Does NOT remember the level: display_sleep() uses it to go dark without forgetting what
// the user chose, and display_wake() restores s_bl_level. Any non-zero level is simply "on" — there is
// no hardware dimming on this pad (see the note above).
static void backlight_set(uint8_t level)
{
    if (!s_bl_ready) return;
    gpio_set_level(BSP_LCD_BL_PWM, level ? BL_ON_LEVEL : BL_OFF_LEVEL);
}

void display_set_brightness(uint8_t level)
{
    s_bl_level = level;
    if (!s_asleep) backlight_set(level);
}

// LVGL flush → copy the rendered area into the frame buffer the panel is scanning.
//
// esp_lcd_panel_draw_bitmap() on an RGB panel is a synchronous memcpy into PSRAM, not a DMA hand-off,
// so the flush is finished by the time it returns and we acknowledge here. (The driver does offer an
// on_color_trans_done callback, but it REQUIRES the callback to live in IRAM — a needless constraint
// when the call is synchronous anyway.)
static void lvgl_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px)
{
    if (!s_asleep) esp_lcd_panel_draw_bitmap(s_panel, area->x1, area->y1, area->x2 + 1, area->y2 + 1, px);
    lv_display_flush_ready(disp);
}

static void tick_cb(void *arg) { lv_tick_inc(2); }

static void lvgl_task(void *arg)
{
    while (1) {
        display_lock();
        uint32_t next = lv_timer_handler();
        if (!s_asleep && lv_display_get_inactive_time(s_disp) > IDLE_MS) display_sleep();
        display_unlock();
        // Report the panel's real refresh rate once, ~2s in. It costs one line in the log and it is the
        // only signal that distinguishes "the RGB engine is scanning" from "every API returned ESP_OK and
        // nothing left the chip" — a distinction that cost a full bring-up day to make the hard way.
        static bool vsync_logged;
        static uint32_t vsync_base, vsync_t0;
        if (!vsync_logged) {
            if (!vsync_t0) { vsync_t0 = lv_tick_get(); vsync_base = s_vsync_count; }
            uint32_t el = lv_tick_get() - vsync_t0;
            if (el >= 2000) {
                vsync_logged = true;
                // Measured over a known window from a known baseline — the counter has been running since
                // panel init, which is earlier than this task, so counting from zero would overstate it.
                // The LCD clock divider rounds, so the measured rate can sit above what the requested
                // pclk and the porches predict. Both numbers are logged so the gap is visible.
                ESP_LOGI(TAG, "panel scanning at ~%u Hz (pclk requested %d MHz)",
                         (unsigned)((s_vsync_count - vsync_base) * 1000 / el), BSP_LCD_PCLK_HZ / 1000000);
            }
        }
        // Keep the loop responsive even while asleep: touch_read (the double-tap-to-wake detector) runs
        // inside lv_timer_handler, so slowing this down slows touch sampling.
        if (next > 20) next = 20;
        vTaskDelay(pdMS_TO_TICKS(next < 2 ? 2 : next));
    }
}

static void panel_bringup(void)
{
    backlight_init();                 // configured dark; light is only asked for at the end of init

    // I2C → expander → panel reset. Nothing below can work if this order is broken, and the failure is
    // silent: the 3-wire SPI writes go into an expander that isn't there, and the panel never leaves
    // reset. board_i2c_get() is idempotent, so calling it here as well as from touch/audio is fine.
    board_i2c_get();
    io_expander_reset_panel();

    esp_io_expander_handle_t exp = io_expander_get();
    if (!exp) ESP_LOGE(TAG, "no IO expander — the ST7701 cannot be programmed");

    spi_line_config_t line = {
        .cs_io_type = IO_TYPE_EXPANDER, .cs_expander_pin = BSP_IO_EXP_LCD_CS,
        .scl_io_type = IO_TYPE_EXPANDER, .scl_expander_pin = BSP_IO_EXP_LCD_SCL,
        .sda_io_type = IO_TYPE_EXPANDER, .sda_expander_pin = BSP_IO_EXP_LCD_SDA,
        .io_expander = exp,
    };
    esp_lcd_panel_io_3wire_spi_config_t io_cfg = ST7701_PANEL_IO_3WIRE_SPI_CONFIG(line, 0);
    esp_lcd_panel_io_handle_t io = NULL;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_3wire_spi(&io_cfg, &io));

    esp_lcd_rgb_panel_config_t rgb = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = ST7701_480_480_PANEL_60HZ_RGB_TIMING(),
        .data_width = 16,
        .bits_per_pixel = BSP_LCD_BIT_PER_PIXEL,
        .num_fbs = 1,                  // ONE frame buffer. Two would remove tearing outright but costs
                                       // another 450 KB of PSRAM and doubles the scan-out bandwidth
                                       // pressure; revisit only if tearing turns out to be real.
        // NO BOUNCE BUFFERS. The DMA reads the PSRAM frame buffer directly.
        //
        // This started at 480*20 px because Waveshare's BSP defaults to a 20-line bounce buffer, and it
        // is the mode IDF's docs recommend for bandwidth headroom. But their own ARDUINO demo — the code
        // that demonstrably lights this board — passes 0, and a bounce-buffered panel that never gets its
        // buffers refilled displays nothing while every API call still returns ESP_OK. Match the
        // configuration that works; the headroom argument is theory against a lit screen.
        //
        // Removing them also gives back ~38 KB of internal RAM and moots the CONFIG_SPIRAM_XIP_FROM_PSRAM
        // caveat in the header comment above: with no refill ISR there is nothing to starve when the
        // cache is disabled. XIP stays on — it is why the panel survives a flash write at all.
        .bounce_buffer_size_px = 0,
        .dma_burst_size = 64,
        .hsync_gpio_num = BSP_LCD_HSYNC,
        .vsync_gpio_num = BSP_LCD_VSYNC,
        .de_gpio_num = BSP_LCD_DE,
        .pclk_gpio_num = BSP_LCD_PCLK,
        .disp_gpio_num = BSP_LCD_DISP,   // -1 on this board: there is no DISP line. See display_sleep().
        .data_gpio_nums = {
            BSP_LCD_DATA0, BSP_LCD_DATA1, BSP_LCD_DATA2,  BSP_LCD_DATA3,
            BSP_LCD_DATA4, BSP_LCD_DATA5, BSP_LCD_DATA6,  BSP_LCD_DATA7,
            BSP_LCD_DATA8, BSP_LCD_DATA9, BSP_LCD_DATA10, BSP_LCD_DATA11,
            BSP_LCD_DATA12, BSP_LCD_DATA13, BSP_LCD_DATA14, BSP_LCD_DATA15,
        },
        .flags = { .fb_in_psram = 1 },
    };
    rgb.timings.h_res = BSP_LCD_H_RES;
    rgb.timings.v_res = BSP_LCD_V_RES;
    rgb.timings.pclk_hz = BSP_LCD_PCLK_HZ;
    // OVERRIDE the component's ST7701_480_480_PANEL_60HZ_RGB_TIMING(). That macro is the driver's generic
    // 480x480 profile (pw/bp/fp = 10/10/20 and 10/10/10); this panel's own numbers come from Waveshare's
    // Arduino demo for THIS board, which is the only configuration anyone has seen light it up:
    //
    //            pulse width   back porch   front porch
    //   hsync         8            50            10        (generic macro: 10, 10, 20)
    //   vsync         8            20            10        (generic macro: 10, 10, 10)
    //
    // The back porches are the ones that matter — 50 against 10 is five times the line-start delay, and a
    // panel that never sees its active window start simply scans nothing. It fails silently: every call
    // still returns ESP_OK and LVGL keeps flushing into a frame buffer nobody displays.
    rgb.timings.hsync_pulse_width = 8;
    rgb.timings.hsync_back_porch  = 50;
    rgb.timings.hsync_front_porch = 10;
    rgb.timings.vsync_pulse_width = 8;
    rgb.timings.vsync_back_porch  = 20;
    rgb.timings.vsync_front_porch = 10;

    // ── ORDER: the RGB panel runs FIRST, the ST7701 is programmed SECOND ────────────────────────────
    //
    // This is why the esp_lcd_st7701 driver is not used here, even though it exists and is what the BSP
    // calls. That driver only offers two orders, and both program the panel before there is any video:
    //
    //   enable_io_multiplex = 1 → registers written inside esp_lcd_new_panel_st7701(), i.e. before
    //                             esp_lcd_new_rgb_panel() has even configured the pins
    //   enable_io_multiplex = 0 → registers written at the top of esp_lcd_panel_init(), still before
    //                             the RGB peripheral is started
    //
    // Waveshare's Arduino demo — the code that lights this board — does the opposite: Arduino_RGB_Display
    // creates AND starts the RGB panel, so HSYNC/VSYNC/DE/PCLK are already running, and only then bangs
    // the init table out through the expander. On this panel that ordering is not cosmetic; with the
    // registers written into a dead bus the part accepts everything and scans nothing.
    //
    // So: build the RGB panel by hand, start it, then send the same table over the same 3-wire SPI. It
    // also drops the driver's own preamble (a page-0 select, MADCTL and COLMOD sent ahead of the table),
    // which the working demo does not send either.
    ESP_ERROR_CHECK(esp_lcd_new_rgb_panel(&rgb, &s_panel));
    const esp_lcd_rgb_panel_event_callbacks_t cbs = { .on_vsync = on_vsync };
    ESP_ERROR_CHECK(esp_lcd_rgb_panel_register_event_callbacks(s_panel, &cbs, NULL));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(s_panel));

    for (size_t i = 0; i < sizeof(s_st7701_init_cmds) / sizeof(s_st7701_init_cmds[0]); i++) {
        const st7701_lcd_init_cmd_t *c = &s_st7701_init_cmds[i];
        esp_err_t e = esp_lcd_panel_io_tx_param(io, c->cmd, c->data, c->data_bytes);
        if (e != ESP_OK) {
            ESP_LOGE(TAG, "ST7701 init cmd %02Xh failed: %s", c->cmd, esp_err_to_name(e));
            break;
        }
        if (c->delay_ms) vTaskDelay(pdMS_TO_TICKS(c->delay_ms));
    }

    // Keep the 3-wire SPI alive rather than deleting it: nothing else wants those three expander pins,
    // and a live handle means brightness-class commands could be sent later without rebuilding it.
    ESP_LOGI(TAG, "ST7701 up: %dx%d, pclk %d MHz, no bounce buffer, %d init cmds",
             BSP_LCD_H_RES, BSP_LCD_V_RES, BSP_LCD_PCLK_HZ / 1000000,
             (int)(sizeof(s_st7701_init_cmds) / sizeof(s_st7701_init_cmds[0])));
}

void display_init(void)
{
    const int draw_lines = DRAW_LINES;
    s_lvgl_mutex = xSemaphoreCreateRecursiveMutex();

    panel_bringup();

    lv_init();

    // Small built-in internal pool for latency-sensitive allocations + the main object pool from PSRAM.
    // Must happen before any LVGL object exists. KEEP IN STEP WITH CONFIG_LV_MEM_POOL_EXPAND_SIZE_KILOBYTES:
    // LVGL sizes its TLSF index from LV_MEM_SIZE + LV_MEM_POOL_EXPAND_SIZE and REJECTS a larger pool at
    // runtime. 64 KiB was measured to fragment into a freeze on the round board (2% → 51% within a
    // minute of ordinary swiping), which is why it is 512 KiB on both.
#define LVGL_PSRAM_POOL_BYTES (512 * 1024)
    s_lvgl_psram_pool = ram_psram_alloc(LVGL_PSRAM_POOL_BYTES, "lvgl_pool");
    if (!s_lvgl_psram_pool) {
        ESP_LOGE(TAG, "required %uKiB LVGL PSRAM pool allocation failed", LVGL_PSRAM_POOL_BYTES / 1024);
        abort();
    }
    if (!lv_mem_add_pool(s_lvgl_psram_pool, LVGL_PSRAM_POOL_BYTES)) {
        ESP_LOGE(TAG, "LVGL rejected the %uKiB PSRAM pool", LVGL_PSRAM_POOL_BYTES / 1024);
        abort();
    }
    ram_telemetry_set_lvgl_ready();
    ram_telemetry_checkpoint("lvgl_pool_ready");

    // Draw buffers in INTERNAL RAM. They are memcpy sources here rather than DMA sources (the flush
    // copies them into the PSRAM frame buffer), but keeping them internal is still what stops the copy
    // from becoming a PSRAM→PSRAM transfer competing with the panel's own scan-out.
    size_t buf_bytes = BSP_LCD_H_RES * draw_lines * BYTES_PER_PX;
    s_buf1 = heap_caps_malloc(buf_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    s_buf2 = heap_caps_malloc(buf_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    if (!s_buf1 || !s_buf2) ESP_LOGE(TAG, "draw buffer alloc failed");
    ESP_LOGI(TAG, "draw buffers %u B x2 (internal); free internal: %u largest: %u",
             (unsigned)buf_bytes, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));

    s_disp = lv_display_create(BSP_LCD_H_RES, BSP_LCD_V_RES);
    lv_display_set_flush_cb(s_disp, lvgl_flush);
    lv_display_set_color_format(s_disp, LV_COLOR_FORMAT_RGB565);   // NATIVE, not swapped — see the header note
    lv_display_set_buffers(s_disp, s_buf1, s_buf2, buf_bytes, LV_DISPLAY_RENDER_MODE_PARTIAL);
    // No rounder callback here on purpose: an RGB panel accepts arbitrary rectangles.

    // The LVGL default theme is light, so the auto-created default screen is WHITE and the refresh task
    // paints it for a few frames on every boot before app_main loads a dark screen. Paint it black up
    // front so boot reads black → content, never a white flash.
    lv_obj_set_style_bg_color(lv_screen_active(), lv_color_black(), 0);
    lv_obj_set_style_bg_opa(lv_screen_active(), LV_OPA_COVER, 0);

    const esp_timer_create_args_t targ = { .callback = tick_cb, .name = "lv_tick" };
    esp_timer_handle_t th;
    ESP_ERROR_CHECK(esp_timer_create(&targ, &th));
    ESP_ERROR_CHECK(esp_timer_start_periodic(th, 2 * 1000)); // 2ms

    touch_init();   // GT911 → LVGL pointer indev (before the handler task runs)

    // Big stack: rendering long wrapped multi-line labels (the event reader) is stack-heavy.
    xTaskCreatePinnedToCore(lvgl_task, "lvgl", 16384, NULL, 4, NULL, 1);

    // Light LAST, once there is a real (black) frame in the buffer to light up.
    backlight_set(s_bl_level);
    ESP_LOGI(TAG, "display + LVGL ready (%dx%d)", BSP_LCD_H_RES, BSP_LCD_V_RES);
}

void display_lock(void)   { xSemaphoreTakeRecursive(s_lvgl_mutex, portMAX_DELAY); }
void display_unlock(void) { xSemaphoreGiveRecursive(s_lvgl_mutex); }

bool display_is_asleep(void) { return s_asleep; }

void display_bump_activity(void) { if (!s_asleep) lv_display_trigger_activity(s_disp); }

// Sleep is the BACKLIGHT, not the panel.
//
// esp_lcd_panel_disp_on_off() needs a DISP GPIO and this board has none (the driver returns
// ESP_ERR_NOT_SUPPORTED with disp_gpio_num < 0), so there is no way to stop an RGB panel scanning short
// of tearing the driver down. That is fine for what sleep is for: on an LCD the backlight IS the light,
// so killing it makes the screen genuinely dark, and pausing LVGL's refresh timer stops the rendering
// work. The scan-out DMA keeps running in the background, costing PSRAM bandwidth nobody is using.
void display_sleep(void)
{
    if (s_asleep) return;
    s_asleep = true;
    backlight_set(0);
    lv_timer_pause(lv_display_get_refr_timer(s_disp));
    ESP_LOGI(TAG, "sleep (backlight off)");
}

void display_wake(void)
{
    if (!s_asleep) return;
    s_asleep = false;                       // clear FIRST so the repaint actually flushes
    lv_timer_resume(lv_display_get_refr_timer(s_disp));
    lv_obj_invalidate(lv_screen_active());
    lv_display_trigger_activity(s_disp);
    backlight_set(s_bl_level);              // back to the user's level, not to full
    ESP_LOGI(TAG, "wake (backlight on)");
}
