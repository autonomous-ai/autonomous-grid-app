// Grid panel — entry point.
//
// Board: Waveshare ESP32-S3-Touch-AMOLED-1.75 — 466x466 round CO5300 AMOLED over QSPI, CST9217 touch
// (mounted 180 degrees to the panel; both axes are mirrored once, in display.c's driver config, and never
// in gesture code), 8 MB octal PSRAM, 16 MB flash with two OTA slots, ES8311 codec with mic and speaker.
//
// ui/display.c is a byte-for-byte copy of the reference firmware's: the CO5300 power-on sequence in it is
// verbatim from Waveshare's own driver, and it is the sort of thing that is right or the panel is black.
//
// The boot flow is short, and it is short on purpose:
//
//   BOOT ─▶ display (QSPI → CO5300 → LVGL) ─▶ carousel ─▶ USB link ─▶ hello ─▶ welcome ─▶ tiles
//
// There is NO WiFi here, no provisioning portal, no pairing, no reconnect ladder, and none of that is
// missing work — it was removed from the design. This panel only ever talks to the one computer it is
// plugged into, over USB, and plugging the cable in IS the authorization: whoever did it was standing in
// front of the machine (docs/panel-protocol.md §4). The reference firmware's boot flow is mostly the
// network getting itself sorted out; there is nothing here for that to become.
//
// ⚠️ NOTHING DRAINS touch_take_longpress(), AND THAT IS THE PORT, NOT AN OVERSIGHT. touch.c is copied
// whole — every recogniser it has, because the gesture layer is the part of this firmware that most
// rewards being left alone — and it still detects a deliberate ≥5 s still-hold. In the reference that
// one-shot opened the WiFi portal or created an agent. Neither exists here: there is no radio, and a
// project is made on the computer. The recogniser stays (it costs nothing and the next screen that wants
// a hold already has one); the ACTION is gone, so the flag is set and never read.
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "fw_update.h"
#include "panel_client.h"
#include "panel_frame.h"
#include "panel_link.h"
#include "power.h"
#include "ram_telemetry.h"
#include "ui/display.h"
#include "ui/ui_screens.h"
#include "audio_capture.h"   // audio_notify_init() — the speaker half of the codec
#include "voice.h"

static const char *TAG = "app";

// How often the RAM/stack line goes out. Slow: it is a trend instrument, not an alarm, and the interesting
// number in it is the one that drifts over hours.
#define TELEMETRY_PERIOD_MS 60000

void app_main(void)
{
    // First, before anything allocates: this installs the PSRAM-first allocator that later JSON parsing
    // uses, and it must be in place before the first cJSON call, not merely before the first message.
    ram_telemetry_init();
    // The version comes out of the running image, which is the same string `hello` reports and the same
    // one grid-app compares against the .bin it carries — see panel_fw_version(). A console line and a
    // handshake that could disagree about which firmware this is would make every update decision
    // unfalsifiable from the log.
    ESP_LOGI(TAG, "grid panel starting — fw %s, framing v%d", panel_fw_version(), PANEL_FRAME_VERSION);
    ram_telemetry_checkpoint("boot");

    // The whole hardware bring-up. Comes first because a panel that cannot draw cannot report any later
    // failure, and this device has no other way to tell anyone anything: its console is on the OTHER USB
    // port, which the person holding it may well not have plugged in.
    display_init();

    // Every screen. ui_init takes the display lock itself — LVGL is not thread-safe and its handler task
    // is already running by now — so this call does not need one around it.
    ui_init();
    ram_telemetry_checkpoint("ui_ready");

    // The PMIC. AFTER the display on purpose: it shares the I2C bus but is not in the panel's critical
    // path. Nothing here has to switch a rail on for the display, so a dark panel is never the PMIC's
    // fault — which is worth stating, because a dark panel makes it look guilty.
    power_init();

    // The 2 MB PSRAM record buffer, reserved BEFORE anything else has had a chance to fragment the
    // heap. A contiguous block that size is easy to get at boot and hard to get later even with
    // megabytes free — and the moment it is actually needed is the moment somebody is holding a finger
    // on the mic, which is the worst possible time to discover it is not there.
    voice_init();
    // The speaker, for the beep on a finished turn. After voice_init because both go through the same
    // I2S/codec bring-up and the mic is the one that must not fail; before the link, so a turn that
    // finishes in the first second still has something to beep with.
    audio_notify_init();

    // Park on the Overview tile with a spinner instead of the "No projects" empty page. The projects
    // have not loaded yet — grid-app has not even said welcome — and flashing an empty state at boot
    // says something false about a computer that may have a dozen. ui_land_after_reload (called by
    // panel_client when the list arrives) drops the spinner and slides to the first project.
    ui_enter_boot_loading();

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

    // If this boot is a freshly installed image, confirm it here and nowhere earlier.
    //
    // With rollback enabled the bootloader reverts an image that never says this, which is the only
    // thing standing between a bad build and a panel that needs a cable, esptool and a person. So the
    // confirmation has to come after the two things that make the panel FIXABLE — it can draw, and the
    // USB link is up so grid-app can offer another image — and no later than that: waiting for a
    // `welcome` would roll back a perfectly good build because nobody had opened the app yet.
    fw_mark_valid();

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
    //
    // It also carries the one piece of UI housekeeping that needs a heartbeat, which is why the loop is
    // 1 s and the telemetry is every sixtieth pass rather than the other way round. The reference runs
    // the same call on the same cadence from its refresh_task.
    int tick = 0;
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));

        // Reap any "Working…" tile whose turn.done was lost or never produced — a grid-app that quit
        // mid-turn, or a message that went down with the cable. Acts on ABSENCE (nothing has stamped
        // that project for >25 s), so a live turn is never cut short: turn.parts keeps stamping.
        ui_prune_stale_busy();

        if (++tick < TELEMETRY_PERIOD_MS / 1000) continue;
        tick = 0;
        uint32_t corrupt = 0, discarded = 0, bad = 0, unknown = 0;
        panel_link_counters(&corrupt, &discarded);
        panel_client_counters(&bad, &unknown);
        ESP_LOGI(TAG, "link: %s corrupt_frames=%u discarded_bytes=%u bad_msgs=%u unknown_msgs=%u",
                 panel_client_is_connected() ? "connected" : "not connected",
                 (unsigned)corrupt, (unsigned)discarded, (unsigned)bad, (unsigned)unknown);
        ram_telemetry_periodic("idle");
    }
}
