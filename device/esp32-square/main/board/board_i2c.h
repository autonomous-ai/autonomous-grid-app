// Shared I2C master bus (SDA/SCL = BSP_I2C_SDA/BSP_I2C_SCL, i.e. GPIO47/48 on this board).
//
// EVERY I2C part is on it: the GT911 touch controller, the TCA9554 IO expander, the AXP2101 PMIC and
// both audio codecs. There can be only ONE bus handle per port, so all of them must come through here —
// a second i2c_new_master_bus() on I2C_NUM_0 fails and takes whatever asked for it out of service.
// Created lazily on first call, which is why board_i2c_get() is safe to call from display, touch and
// power without any of them owning the order.
//
// The reference firmware's copy of this comment named SDA=15/SCL=14 and a CST9217 touch controller —
// both from the round AMOLED sibling this file was forked from, neither true here. Corrected on the way
// in, and stated as a reference to the macros so it cannot go stale the same way again.
#pragma once

#include "driver/i2c_master.h"

// Returns the shared I2C master bus handle (creates it once). NULL on failure.
i2c_master_bus_handle_t board_i2c_get(void);
