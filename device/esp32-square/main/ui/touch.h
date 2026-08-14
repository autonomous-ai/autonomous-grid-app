// GT911 capacitive touch → LVGL pointer indev.
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Bring up the GT911 on the shared I2C bus and register an LVGL pointer indev. Call after lv_init() and
// before the LVGL handler task starts (display.c does both).
//
// Tolerant by design: on any failure it logs and returns, leaving a working display with no touch. A
// panel you can read but not poke is a far better failure than a boot loop, and this device's job —
// showing what the machine is doing — still mostly works without a finger.
void touch_init(void);
