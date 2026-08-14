// Display bring-up: ST7701 over 16-bit RGB parallel, 480x480, + the LVGL v9 port.
//
// The reference firmware keeps this header deliberately stale (it still describes a CO5300 AMOLED over
// QSPI) because three boards share the contract and none of them may learn which panel it is talking to.
// There is one board here, so the header says what is actually behind it.
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Bring up I2C → IO expander → panel reset → RGB → ST7701 registers → LVGL, add the PSRAM object pool,
// allocate the internal-DMA draw buffers, register touch and spawn the LVGL handler task.
//
// That order is the whole job: the ST7701's init registers travel over a 3-wire SPI bit-banged on the
// TCA9554, not on the 16 data lines, so anything that touches the panel before the expander is alive
// silently does nothing. See the ORDER note in display.c.
void display_init(void);

// Backlight on/off. The pad is an ENABLE, not a dimmer — any non-zero level is simply "on" (three
// measurements behind that, in display.c). Kept as a level so the call site reads the same as it would
// on a board that does dim, and so display_sleep() can go dark without forgetting the chosen level.
void display_set_brightness(uint8_t level);

// Lock/unlock the LVGL mutex. ANY code touching LVGL objects from outside the LVGL task — the USB link
// task, anything that draws in response to a message — must hold this. LVGL is not thread-safe and the
// failure mode is a corrupted display list, not an error.
void display_lock(void);
void display_unlock(void);

// Idle blank: kill the backlight and pause LVGL's refresh timer. `display_wake()` repaints and re-arms
// the idle timer. Both run on the LVGL task (the idle check and the touch wake).
void display_sleep(void);
void display_wake(void);
bool display_is_asleep(void);

// Reset the idle-off timer without a touch. For activity the touchscreen cannot see — a turn running on
// the desktop, a voice capture driven by the PWR key — where blanking the panel would be wrong.
void display_bump_activity(void);

// VSYNC count since panel init. The ONLY evidence that the RGB timing engine is actually scanning:
// every other signal is an API return code, and those stay ESP_OK whether or not a pixel clock ever
// leaves the chip.
uint32_t display_vsync_count(void);
