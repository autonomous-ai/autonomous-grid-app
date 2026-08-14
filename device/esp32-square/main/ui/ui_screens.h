// The panel's screens.
//
// One screen so far. It exists because a display that comes up black is indistinguishable from a display
// that did not come up at all, and this firmware's whole hardware layer fails silently — the ST7701
// accepts every register write with the RGB bus dead, the TCA9554 returns ESP_OK for a pin it is not
// driving. A legible screen is the only end-to-end proof that the chain worked.
//
// EVERY function here must be called with display_lock() held, or from the LVGL task. LVGL is not
// thread-safe and the failure is a corrupted display list rather than an error return.
#pragma once

// Build the screens and show the disconnected state. Call once, after display_init().
void ui_screens_init(void);

// "Not connected" — no machine is talking to this panel.
void ui_show_not_connected(void);
