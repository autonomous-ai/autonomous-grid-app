// CST9217 capacitive touch → LVGL pointer indev (enables tileview swipe).
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Initialize I2C + CST9217 + register an LVGL pointer indev. Call after lv_init().
// Tolerant: logs and returns on failure (display still works, just no touch).
void touch_init(void);

// Drop a deferred single tap that something else has already acted on (e.g. an Overview row that jumped
// to an agent). Without it that press fires again, on the page it just navigated to.
void ui_tap_cancel(void);

// One-shot: returns true once after a deliberate long-press (~1.5s hold). Used by the no-WiFi
// standby loop to open the setup portal on purpose (a stray pocket brush won't trigger it).
bool touch_take_longpress(void);

// Monotonic generation bumped once for every physical touch press. Background rendering, voice, and
// programmatic display activity do not affect it, so callers can cheaply detect real user interaction.
uint32_t touch_activity_generation(void);
