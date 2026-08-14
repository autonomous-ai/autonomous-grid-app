// TCA9554 IO expander — the thing this board puts between the SoC and hardware that both sibling
// boards reach with a plain GPIO.
//
// Three unrelated consumers share ONE chip, which is why this lives in its own file instead of inside
// display.c: the panel's 3-wire SPI (CS/SDA/SCL), the panel reset, and the speaker power amp. The
// expander therefore has to exist before the display AND before audio, and it needs the I2C bus first.
// Bring-up order is not negotiable:  board_i2c_get() → io_expander_get() → panel → audio.
//
// Everything here is safe to call before the expander answers: each entry point brings it up on demand
// and returns quietly if the chip is not on the bus, so a wiring fault shows up as "no picture" or "no
// beep" rather than a boot loop.
#pragma once

#include <stdbool.h>
#include "esp_io_expander.h"

// Shared handle, created on first use. NULL if the TCA9554 does not answer on the I2C bus.
esp_io_expander_handle_t io_expander_get(void);

// Pulse the panel's reset lines. Waveshare's BSP drives TWO expander pins here (5 and 6) with 200ms
// between each step, and leaves pin 6 as an INPUT afterwards — reproduced exactly, because the sequence
// is the vendor's and a panel that does not come up is indistinguishable from a wrong pin map.
void io_expander_reset_panel(void);

// Speaker power amp (expander pin 3). audio_capture.c calls this instead of toggling a GPIO — on the
// round board the codec driver owns the PA pin, but esp_codec_dev can only drive a real GPIO, so the
// amp is enabled here for the lifetime of the audio stack.
void io_expander_pa_enable(bool on);
