// GT911 touch → LVGL pointer indev.
//
// touch_init() is lifted verbatim from autonomous-code/apps/esp32-square-s3 (the board facts in it are
// the point). touch_read() is NOT: the reference's is ~150 lines of gesture recognition — double-tap to
// start voice, deferred single taps, edge swipes, a notification drawer — written against a UI that does
// not exist here. Porting gestures before there are screens to gesture at would be porting decisions,
// not code. So this reads coordinates, wakes the screen, and hands the point to LVGL; gestures come back
// one at a time when a screen needs one, from that file.
#include "touch.h"
#include "board_pins.h"
#include "board_i2c.h"
#include "display.h"
#include "driver/i2c_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "touch";
static esp_lcd_touch_handle_t s_tp;

// LVGL reads the latest touch point. Marshalled by LVGL's own task, so reading the GT911 over I2C from
// here is fine — the LVGL task holds no lock the I2C driver wants.
static void touch_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    if (!s_tp) { data->state = LV_INDEV_STATE_RELEASED; return; }

    uint16_t x = 0, y = 0, strength = 0;
    uint8_t cnt = 0;
    esp_lcd_touch_read_data(s_tp);
    // esp_lcd_touch_get_coordinates() is deprecated in esp_lcd_touch 1.2 in favour of
    // esp_lcd_touch_get_data(), and the build says so. Kept anyway: this is the call the reference
    // firmware runs on this board, the replacement has not been exercised on this hardware by anyone
    // here, and touch is one of the two things that cannot be checked without the panel in hand. Swap it
    // when someone is holding the device, not before.
    bool pressed = esp_lcd_touch_get_coordinates(s_tp, &x, &y, &strength, &cnt, 1) && cnt > 0;

    // Asleep: the touch that wakes the screen must not ALSO land as a press on whatever was showing when
    // it blanked. Swallow the whole gesture until the finger lifts — otherwise the tap that wakes the
    // panel also activates the thing under the finger, which reads as the device acting on its own.
    static bool swallow;
    if (display_is_asleep()) {
        if (pressed) { display_wake(); swallow = true; }
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }
    if (swallow) {
        if (pressed) { data->state = LV_INDEV_STATE_RELEASED; return; }
        swallow = false;
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
    // Shared I2C master bus — one handle per port, and the expander and PMIC are on it too.
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
        // which is what touch_read() above already does, so nothing above this line changes.
        .int_gpio_num = BSP_TOUCH_INT,
        // Orientation is DELIBERATELY neutral, not copied. The reference firmware's round sibling needs
        // mirror_x/mirror_y because its controller is mounted 180° to the panel; that is a fact about
        // that board's assembly and says nothing about this one. Establish the truth on hardware — drag
        // a finger left, check the UI follows — and set these flags from what you observe.
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
