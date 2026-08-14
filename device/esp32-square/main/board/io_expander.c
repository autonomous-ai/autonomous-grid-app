#include "io_expander.h"
#include "board_i2c.h"
#include "board_pins.h"
#include "esp_io_expander_tca9554.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

static const char *TAG = "io_exp";
static esp_io_expander_handle_t s_exp;

esp_io_expander_handle_t io_expander_get(void)
{
    if (s_exp) return s_exp;
    i2c_master_bus_handle_t bus = board_i2c_get();
    if (!bus) { ESP_LOGE(TAG, "no i2c bus"); return NULL; }
    esp_err_t err = esp_io_expander_new_i2c_tca9554(bus, BSP_IO_EXP_ADDR_000, &s_exp);
    if (err != ESP_OK) {
        // Not fatal on its own. Say what it costs, because the symptoms land far from here: no panel
        // reset (dark screen) and no speaker amp (silent beeps), with nothing else looking wrong.
        ESP_LOGE(TAG, "TCA9554 not found at 0x%02X (%s) — panel and speaker will not come up",
                 BSP_IO_EXP_ADDR_000, esp_err_to_name(err));
        s_exp = NULL;
    }
    return s_exp;
}

void io_expander_reset_panel(void)
{
    esp_io_expander_handle_t exp = io_expander_get();
    if (!exp) return;

    // Verbatim from Waveshare's BSP (bsp/esp32_s3_touch_lcd_4b, bsp_display_new). Two pins, three
    // 200ms waits, and pin 6 ends as an INPUT rather than being driven high — that last step is
    // deliberate in the vendor code and is kept. If the panel stays dark, try swapping the two pins
    // before suspecting the ST7701 timings: this sequence is the least documented part of the board.
    esp_io_expander_set_dir(exp, BSP_IO_EXP_RST_A | BSP_IO_EXP_RST_B, IO_EXPANDER_OUTPUT);
    esp_io_expander_set_level(exp, BSP_IO_EXP_RST_B, 0);
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_io_expander_set_level(exp, BSP_IO_EXP_RST_A, 0);
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_io_expander_set_level(exp, BSP_IO_EXP_RST_A, 1);
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_io_expander_set_dir(exp, BSP_IO_EXP_RST_B, IO_EXPANDER_INPUT);

    // And pin 7, which the BSP never touches. Waveshare's Arduino demo pulses it inside its expander
    // wrapper (Arduino_XCA9554SWSPI::begin: low, 10ms, high, 100ms) and treats it as the panel reset;
    // without it this panel initialises cleanly over the 3-wire SPI and stays black. The TCA9554 comes up
    // with every pin an input, so "not driven" is the state that fails.
    esp_io_expander_set_dir(exp, BSP_IO_EXP_LCD_EN, IO_EXPANDER_OUTPUT);
    esp_io_expander_set_level(exp, BSP_IO_EXP_LCD_EN, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    esp_io_expander_set_level(exp, BSP_IO_EXP_LCD_EN, 1);
    vTaskDelay(pdMS_TO_TICKS(100));

    ESP_LOGI(TAG, "panel reset pulsed (expander pins 5/6 + 7)");
}

void io_expander_pa_enable(bool on)
{
    esp_io_expander_handle_t exp = io_expander_get();
    if (!exp) return;
    esp_io_expander_set_dir(exp, BSP_IO_EXP_PA_EN, IO_EXPANDER_OUTPUT);
    esp_io_expander_set_level(exp, BSP_IO_EXP_PA_EN, on ? 1 : 0);
}
