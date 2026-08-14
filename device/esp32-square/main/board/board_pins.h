// Pin map for the Waveshare ESP32-S3-Touch-LCD-4B ("Smart 86 Box" wall panel).
//
// Lifted from autonomous-code/apps/esp32-square-s3, which runs on this exact board. Everything here was
// paid for by someone else's bring-up; the only edit on the way in is the backlight comment, which
// contradicted the code it cited (see BSP_LCD_BL_PWM below).
//
// Source of truth is Waveshare's own BSP:
// github.com/waveshareteam/Waveshare-ESP32-components → bsp/esp32_s3_touch_lcd_4b.
//
// DO NOT take pins from the wiki page for this board. That page is contaminated with content from an
// AMOLED sibling: its Arduino sections talk about a CO5300 panel over QSPI (LCD_SDIO0..3) and a CST9217
// touch controller, none of which exist here, and it carries no GPIO table at all. Only its "Hardware
// Description / Onboard Resources" section describes THIS board. Everything below comes from the BSP;
// anything marked UNVERIFIED still needs a measurement before it is treated as fact.
#pragma once

// ---- Panel: ST7701 over 16-bit RGB parallel (NOT QSPI, NOT MIPI-DSI) ----
// Both sibling boards are a different world: the round board drives a CO5300 over QSPI, the P4 square
// board drives an ST7703 over 2-lane MIPI-DSI. What is specific to RGB here: the panel scans its frame
// buffer out of PSRAM CONTINUOUSLY (see ui/display.c and ota.c), and the ST7701's own init sequence does
// not travel on these wires at all — it goes over a 3-wire SPI bit-banged on the IO expander (below).
#define BSP_LCD_H_RES         480
#define BSP_LCD_V_RES         480
#define BSP_LCD_BIT_PER_PIXEL 16          // RGB565, NATIVE byte order (the round board renders swapped)

#define BSP_LCD_VSYNC         3
#define BSP_LCD_HSYNC         46
#define BSP_LCD_DE            17
#define BSP_LCD_PCLK          9
// Backlight ENABLE. ACTIVE-LOW, and NOT a PWM — despite the name, which is the BSP's and is kept only so
// this file still diffs cleanly against the reference firmware it came from.
//
// ⚠️ The reference's copy of this line said "real backlight PWM (LEDC), ACTIVE-HIGH" and pointed at
// ui/display.c for detail. That file reaches the OPPOSITE conclusion and records the three measurements
// that got it there: the pad blinks the panel (so it is the backlight), holding it HIGH with a white frame
// in the buffer leaves the panel black (so HIGH is OFF), and LEDC at 5 kHz gave no light at any duty in
// either polarity (so the pad GATES a boost converter instead of modulating one — there is no hardware
// dimming). display.c has always defined BL_ON_LEVEL 0 accordingly. The comment was simply never updated,
// and a comment that contradicts working code is worse than no comment: it sends the next person to
// "fix" the code. Corrected on the way in; the code was not touched.
#define BSP_LCD_BL_PWM        4
// RST and DISP are not wired to the SoC on this board; the panel is reset through the IO expander.
#define BSP_LCD_RST           (-1)
#define BSP_LCD_DISP          (-1)

// Data bus, D0..D15 (RGB565: D0-4 = blue, D5-10 = green, D11-15 = red).
#define BSP_LCD_DATA0         40
#define BSP_LCD_DATA1         41
#define BSP_LCD_DATA2         42
#define BSP_LCD_DATA3         2
#define BSP_LCD_DATA4         1
#define BSP_LCD_DATA5         21
#define BSP_LCD_DATA6         8
#define BSP_LCD_DATA7         18
#define BSP_LCD_DATA8         45
#define BSP_LCD_DATA9         38
#define BSP_LCD_DATA10        39
#define BSP_LCD_DATA11        10
#define BSP_LCD_DATA12        11
#define BSP_LCD_DATA13        12
#define BSP_LCD_DATA14        13
#define BSP_LCD_DATA15        14

// Pixel clock. 12 MHz, which is what Waveshare's ARDUINO demo actually runs on this board:
// Arduino_ESP32RGBPanel::begin() picks 12 MHz for octal PSRAM (6 MHz for quad). Their ESP-IDF BSP says
// 16 MHz — one more place the two disagree, and the demo is the one that lights the panel.
//
// It is also the right knob if anything ever starves: scan-out reads 2 bytes per pixel clock straight
// out of PSRAM, so 12 MHz is ~24 MB/s of the ~50-60 MB/s this octal PSRAM really delivers.
#define BSP_LCD_PCLK_HZ       (12 * 1000 * 1000)

// ---- I2C bus (touch + IO expander + both audio chips + PMIC + IMU + RTC all share it) ----
#define BSP_I2C_SDA           47
#define BSP_I2C_SCL           48
#define BSP_I2C_FREQ_HZ       400000

// ---- IO expander: TCA9554 (I2C) ----
// This board puts things behind the expander that both sibling boards have on real GPIOs, which is why
// board/io_expander.c exists and why the bring-up ORDER is not negotiable: I2C → expander → panel reset
// → RGB. Anything that touches the panel or the speaker before the expander is up silently does nothing.
// ⚠️ THESE ARE BITMASKS, NOT PIN INDICES. esp_io_expander's API takes esp_io_expander_pin_num_t, which
// is an enum of (1 << n) values — esp_io_expander_set_dir/set_level and spi_line_config_t all expect a
// mask. Writing the plain pin number here compiles, runs, returns ESP_OK, and drives the WRONG PIN:
// 0 addresses nothing at all, 1 addresses pin 0, 2 addresses pin 1.
//
// That is not hypothetical. This file first defined CS/SDA/SCL as 0/1/2 and the panel stayed black for a
// day: CS went nowhere, SDA landed on the CS pad, SCL landed on the SDA pad, and the real clock line
// (pin 2) was never even switched to an output — so the ST7701 received not one bit while every API call
// reported success. The tell was the TCA9554's own CONFIG register reading 0x5C, i.e. bit 2 still an
// input. If a pin here ever looks dead again, read register 0x03 back before suspecting anything else.
#define BSP_IO_EXP_ADDR_000   0x20        // TCA9554 with all address straps low
#define BSP_IO_EXP_LCD_CS     (1U << 0)   // ST7701 3-wire SPI chip select
#define BSP_IO_EXP_LCD_SDA    (1U << 1)   // ST7701 3-wire SPI data
#define BSP_IO_EXP_LCD_SCL    (1U << 2)   // ST7701 3-wire SPI clock
#define BSP_IO_EXP_PA_EN      (1U << 3)   // NS4150-class speaker power-amp enable
#define BSP_IO_EXP_RST_A      (1U << 5)   // panel reset, half one   (see io_expander_reset_panel)
#define BSP_IO_EXP_RST_B      (1U << 6)   // panel reset, half two
// The pin Waveshare's own BSP forgets and their Arduino demo does not. Arduino_GFX drives it as the
// panel's reset (low 10ms, high, settle 100ms) inside Arduino_XCA9554SWSPI::begin(); leaving it as a
// high-Z input — which is what the TCA9554 powers up as — gives a panel that initialises without error
// and shows nothing at all. Found by diffing the working demo against this firmware, not from any doc.
#define BSP_IO_EXP_LCD_EN     (1U << 7)

// ---- Capacitive touch: GT911 (I2C), 5-point ----
// INT and RST are both unconnected on this board, so the driver must be built with
// int_gpio_num = GPIO_NUM_NC and POLLED — exactly like the P4 square board. There is no interrupt.
#define BSP_TOUCH_I2C_ADDR    0x5D        // GT911 default; VERIFIED — the controller answers here
#define BSP_TOUCH_INT         (-1)
#define BSP_TOUCH_RST         (-1)

// ---- Audio: dual-mic → ES7210 ADC (capture) + ES8311 codec + speaker (8Ω 2W, MX1.25) ----
// ⚠️ UNVERIFIED, and the failure mode is SILENCE rather than an error: the BSP names GPIO5 as MCLK and
// GPIO16 as SCLK, which is the reverse of the usual ordering on Waveshare's other boards. The P4 sibling
// hit exactly this class of contradiction (its wiki and its BSP disagreed on the I2S roles). Confirm with
// a capture — record 1s of PCM and check the RMS is non-zero — before debugging audio_capture.c itself.
#define BSP_I2S_MCLK          5
#define BSP_I2S_BCLK          16          // "SCLK" in the BSP
#define BSP_I2S_WS            7           // "LCLK"
#define BSP_I2S_DOUT          6           // ESP → codec (speaker)
#define BSP_I2S_DIN           15          // codec → ESP (mic capture)
// The power amp is NOT a GPIO on this board (it is expander pin 3), so BSP_PA_IO does not exist here.
// audio_capture.c drives it through io_expander_pa_enable() instead.

// ---- Power management: AXP2101 (I2C) ----
// VERIFIED on the board: it answers at 0x34 and power.c logs "AXP2101 ready". The BSP does not touch the
// PMIC at all (it declares BSP_CAPS_BUTTONS 0), so this came from the wiki's hardware list and
// Waveshare's own 01_AXP2101 demo, and then from the device itself.
//
// Its rails are all ON at reset — measured during bring-up: DCDC enable (0x80) = 0x0F, LDO enables
// (0x90/0x91) = 0xFF/0x01. Worth knowing because a dark panel makes the PMIC look guilty and it is not:
// nothing here has to switch a rail on for the display.
#define BSP_AXP2101_I2C_ADDR  0x34

// ---- Buttons ----
// PWRKEY is wired to the AXP2101's PWRON pin (read over I2C, not as a GPIO) — same as the round board.
#define BSP_BOOT_BUTTON       0           // hold at power-on to factory-reset
