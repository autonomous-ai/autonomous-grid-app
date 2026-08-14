// Grid panel — entry point.
//
// Board: Waveshare ESP32-S3-Touch-LCD-4B, 480x480 IPS over 16-bit RGB parallel (ST7701), GT911 touch,
// TCA9554 IO expander, AXP2101 PMIC. See docs/hardware.md for what was measured on it and what was
// inherited from the reference firmware in autonomous-code/apps/esp32-square-s3.
//
// The boot flow is short, and it is short on purpose:
//
//   BOOT ─▶ display (I2C → expander → panel reset → RGB → ST7701 → LVGL) ─▶ "Not connected" ─▶ USB link
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
#include "panel_frame.h"
#include "panel_link.h"
#include "power.h"
#include "ram_telemetry.h"
#include "ui/display.h"
#include "ui/ui_screens.h"

static const char *TAG = "app";

// Reported to grid-app in the `hello` message once the message layer exists, and printed at boot so a
// device on someone's desk can be identified from its console alone.
#define PANEL_FW_VERSION "0.1.0"

// How often the RAM/stack line goes out. Slow: it is a trend instrument, not an alarm, and the interesting
// number in it is the one that drifts over hours.
#define TELEMETRY_PERIOD_MS 60000

// Every frame that arrives, until there is a message layer to hand them to.
//
// Runs on the link task with the payload pointing into the decoder's buffer — valid for this call only.
// Logging is the entire body deliberately: a stub that quietly drops frames looks identical to a link
// that is not receiving, and telling those apart is the first thing anyone bringing this up will need.
static void on_frame(uint8_t version, uint8_t type, const uint8_t *payload, size_t payload_len, void *ctx)
{
    (void)payload;
    (void)ctx;
    // An unknown type is NOT an error at this layer — it is handed up with its raw byte so that a
    // grid-app running ahead of this firmware reads as a version mismatch someone can act on, rather
    // than as a link that connects and then goes quiet.
    ESP_LOGI(TAG, "frame: ver=%u type=0x%02X len=%u", version, type, (unsigned)payload_len);
}

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

    // Last: the USB link. Deliberately after the screen, so the panel is already showing "Not connected"
    // if this fails — the failure and its report are then the same picture.
    if (!panel_link_start(on_frame, NULL)) {
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
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(TELEMETRY_PERIOD_MS));
        uint32_t corrupt = 0, discarded = 0;
        panel_link_counters(&corrupt, &discarded);
        ESP_LOGI(TAG, "link: corrupt_frames=%u discarded_bytes=%u vsync=%u",
                 (unsigned)corrupt, (unsigned)discarded, (unsigned)display_vsync_count());
        ram_telemetry_periodic("idle");
    }
}
