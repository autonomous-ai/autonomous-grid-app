// Grid panel — entry point.
//
// Board: Waveshare ESP32-S3-Touch-LCD-4B, 480x480 IPS over 16-bit RGB parallel (ST7701), GT911 touch,
// TCA9554 IO expander, AXP2101 PMIC. See docs/hardware.md for what was measured on it and what was
// inherited from the reference firmware in autonomous-code/apps/esp32-square-s3.
//
// The boot flow is short, and it is short on purpose:
//
//   BOOT ─▶ display (I2C → expander → panel reset → RGB → ST7701 → LVGL) ─▶ "Not connected" ─▶ USB link
//                                                                                              ─▶ hello ─▶ tiles
//
// There is NO WiFi here, no provisioning portal, no pairing, no reconnect ladder, and none of that is
// missing work — it was removed from the design. This panel only ever talks to the one computer it is
// plugged into, over USB, and plugging the cable in IS the authorization: whoever did it was standing in
// front of the machine (docs/overview.md). The reference firmware's boot flow is mostly the network
// getting itself sorted out; there is nothing here for that to become.
//
// ⚠️ THE ORDER BELOW IS NOT NEGOTIABLE, and every step of it fails silently if you break it. The
// ST7701's init registers do not travel on the 16 data lines — they go over a 3-wire SPI bit-banged on
// the IO expander — so the I2C bus must exist before the expander, the expander before the panel reset,
// and the reset before the RGB peripheral. Skip one and the panel is black with every API call returning
// ESP_OK. display_init() owns that whole sequence; nothing here may reorder it from the outside.
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "panel_client.h"
#include "panel_frame.h"
#include "panel_link.h"
#include "power.h"
#include "ram_telemetry.h"
#include "ui/display.h"
#include "ui/ui_screens.h"

static const char *TAG = "app";

// How often the RAM/stack line goes out. Slow: it is a trend instrument, not an alarm, and the interesting
// number in it is the one that drifts over hours.
#define TELEMETRY_PERIOD_MS 60000

void app_main(void)
{
    // First, before anything allocates: this installs the PSRAM-first allocator that later JSON parsing
    // uses, and it must be in place before the first cJSON call, not merely before the first message.
    ram_telemetry_init();
    ESP_LOGI(TAG, "grid panel starting — fw %s, framing v%d", PANEL_FW_VERSION, PANEL_FRAME_VERSION);
    ram_telemetry_checkpoint("boot");

    // The whole hardware bring-up, in the one order that works. Comes first because a panel that cannot
    // draw cannot report any later failure, and this device has no other way to tell anyone anything:
    // its console is on the OTHER USB port, which the person holding it may well not have plugged in.
    display_init();

    // LVGL is not thread-safe and its handler task is already running by now, so anything touching an
    // LVGL object from app_main takes the lock. The failure without it is a corrupted display list —
    // not an error return, and not reproducible on demand.
    display_lock();
    ui_screens_init();
    display_unlock();
    ram_telemetry_checkpoint("ui_ready");

    // AXP2101, for battery state in a future status bar. AFTER the display on purpose: it shares the I2C
    // bus but is not in the panel's critical path, and every rail it controls is already ON at reset
    // (measured during the reference firmware's bring-up: DCDC enable 0x80 = 0x0F, LDO enables 0x90/0x91
    // = 0xFF/0x01). Nothing here has to switch a rail on for the display, so a dark panel is never the
    // PMIC's fault — which is worth stating, because a dark panel makes it look guilty.
    power_init();

    // Last: the link and the conversation on it. Deliberately after the screen, so the panel is already
    // showing "Not connected" if this fails — the failure and its report are then the same picture.
    //
    // panel_client owns the whole of it: it starts panel_link with its own frame handler, says hello
    // until grid-app answers, and pushes what comes back into the screens. Nothing above it has to know
    // there is a USB port involved.
    if (!panel_client_start()) {
        ESP_LOGE(TAG, "no usb link — the panel will show 'Not connected' and stay there");
    }
    ram_telemetry_checkpoint("link_ready");

    // app_main must not return; returning deletes the task and takes its stack with it. Park it on the
    // telemetry line rather than a bare delay so the loop earns its existence: internal RAM, PSRAM, the
    // LVGL pool and the long-lived task stack high-water marks, every minute.
    //
    // Framing counters ride along because the RATE is the diagnosis. A few discarded bytes right after
    // boot are the ROM and bootloader's parting words on this port and are expected; a steady trickle
    // during a session means the two sides disagree about the format, or the cable is bad. Without a
    // count over time those two look exactly alike.
    //
    // The message-layer counters are on the same line and are read the same way, but they mean different
    // things from each other: `bad` is a payload that was not readable JSON — corruption, or a bug on
    // one side — while `unknown` is a message this build simply has no case for, which is a grid-app
    // running ahead of this firmware and is not a fault at all.
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(TELEMETRY_PERIOD_MS));
        uint32_t corrupt = 0, discarded = 0, bad = 0, unknown = 0;
        panel_link_counters(&corrupt, &discarded);
        panel_client_counters(&bad, &unknown);
        ESP_LOGI(TAG, "link: %s corrupt_frames=%u discarded_bytes=%u bad_msgs=%u unknown_msgs=%u vsync=%u",
                 panel_client_is_connected() ? "connected" : "not connected",
                 (unsigned)corrupt, (unsigned)discarded, (unsigned)bad, (unsigned)unknown,
                 (unsigned)display_vsync_count());
        ram_telemetry_periodic("idle");
    }
}
