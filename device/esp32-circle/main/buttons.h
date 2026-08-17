// The two physical buttons on the round board.
//
// | Button | Wired to                        | Short press          | Long press                        |
// |--------|---------------------------------|----------------------|-----------------------------------|
// | PWR    | AXP2101 PWRON (I2C, NOT a GPIO) | screen off / on      | AXP2101 restarts the device       |
// | BOOT   | GPIO0, active-low               | back / cancel a turn | (nothing; held at power-on only)  |
//
// The long press is the reason the PWR key gets called "the reset button": the PMIC power-cycles the
// board in hardware, at REG 0x27, and software never sees it. This file deliberately leaves that
// register alone — the tap and the restart are the same button, and taking the restart away to get the
// tap would cost the one recovery a person holding the device still has.
//
// Named for what it does. The reference firmware called this ptt.c, from a time when the button was
// push-to-talk; voice has been gesture-driven (double-tap) since, and its own header still described
// the old behaviour while the code did something else.
#pragma once

// Start the button poll task. Call after ui_init (BOOT reaches into the screens) and after power_init
// (which arms the PWR key's press event on the PMIC — without it the tap is never latched).
void buttons_start(void);
