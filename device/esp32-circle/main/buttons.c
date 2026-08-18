#include "buttons.h"

#include "board/board_pins.h"
#include "board/power.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ui/display.h"
#include "ui/ui_screens.h"

static const char *TAG = "buttons";

// AXP2101 PWR-key poll cadence. Latency only, not a race: the PMIC LATCHES the press event in its IRQ
// status register, so a press between two polls is still there when we look. 100ms is under what a
// person reads as instant.
#define POLL_MS 100

static void buttons_task(void *arg)
{
    // BOOT (GPIO0, active-low). Pulled up because the button is the only thing that drives it low; with
    // no pull the pin floats and the "press" is whatever noise the board picks up.
    gpio_config_t bcfg = {
        .pin_bit_mask = 1ULL << BSP_BOOT_BUTTON,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&bcfg);
    int boot_prev = 1;   // released (active-low: 1 = up, 0 = pressed)

    while (1) {
        // One short press of the PWR key → toggle the screen.
        if (power_take_pwrkey_tap()) {
            // Hold the LVGL lock: display_sleep/wake pause and resume LVGL's refresh timer and invalidate
            // the active screen, and they normally run on the LVGL task. The mutex is recursive, so this
            // serialises with that task rather than deadlocking against it.
            display_lock();
            if (display_is_asleep()) {
                ESP_LOGI(TAG, "PWR tap -> screen ON");
                display_wake();
            } else {
                ESP_LOGI(TAG, "PWR tap -> screen OFF");
                display_sleep();
            }
            display_unlock();
        }

        // BOOT: act on the falling edge only, so holding it does one thing rather than one per poll.
        int boot_now = gpio_get_level(BSP_BOOT_BUTTON);
        if (boot_prev == 1 && boot_now == 0) {
            // A press on a dark screen means "wake", never "cancel the turn I cannot see". Same rule the
            // touchscreen follows (touch.c swallows the waking touch), and it matters more here: BOOT can
            // pop the "Cancel task?" confirm, and answering a question nobody was shown is how a running
            // turn dies to a button someone pressed to look at it.
            if (display_is_asleep()) {
                display_lock();
                display_wake();
                display_unlock();
            } else {
                ESP_LOGI(TAG, "BOOT press -> back / cancel turn");
                ui_boot_pressed();
            }
        }
        boot_prev = boot_now;

        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
    }
}

void buttons_start(void)
{
    // Priority 3 — below the LVGL task (4) so polling two buttons never preempts rendering. The task
    // spends essentially all of its life in vTaskDelay; the stack is for the I2C transaction and the
    // ui_boot_pressed call.
    if (xTaskCreate(buttons_task, "buttons", 4096, NULL, 3, NULL) != pdPASS) {
        // Said out loud rather than swallowed: the symptom is a button that does nothing, which reads as
        // broken hardware and is the last thing anyone would suspect a failed task creation of.
        ESP_LOGE(TAG, "could not start the button task — PWR and BOOT will do nothing");
    }
}
