# Single "main" component holding every source. Board drivers live under board/, the LVGL UI under ui/.
#
# panel_frame.c is listed here AND compiled separately by ../scripts/test_frame.sh with a plain host
# compiler. That is why it must stay free of ESP-IDF headers: the moment it includes one, the host test
# stops building and the only cheap check on the wire format goes with it.
idf_component_register(
    SRCS
        "app_main.c"
        "audio_capture.c"
        "fw_update.c"
        "panel_client.c"
        "panel_frame.c"
        "panel_link.c"
        "ram_telemetry.c"
        "voice.c"
        "board/board_i2c.c"
        "board/io_expander.c"
        "board/power.c"
        "ui/display.c"
        "ui/touch.c"
        "ui/ui_screens.c"
        # Development instrument, not product code — see ui/ui_screenshot.c. Compiled in because it costs
        # one function and no runtime work until the host asks for a shot.
        "ui/ui_screenshot.c"
        # Fonts and icons: generated C arrays, lifted whole from the reference firmware.
        #
        # Listing all of them costs build time and NOT flash — each is its own object file in libmain.a,
        # so the linker only pulls in the ones something actually names. Verified: with the screen using
        # two of them, `nm` on the .elf finds exactly geist_med_25 and geist_reg_16 and none of the rest.
        #
        # They are all here now because regenerating one later needs the .ttf, the LVGL font converter
        # and the exact glyph ranges — none of which are in this repo, and the ranges in particular were
        # chosen to cover Vietnamese, which is not something to rediscover under time pressure.
        "ui/geist_reg_13.c"
        "ui/geist_reg_16.c"
        "ui/geist_reg_24.c"
        "ui/geist_reg_25.c"
        "ui/geist_med_21.c"
        "ui/geist_med_25.c"
        "ui/geist_med_56.c"
        "ui/icons_engine.c"
        "ui/icons_settings.c"
        "ui/icons_voice.c"
        "ui/spinner_spokes.c"
    INCLUDE_DIRS
        "."
        "ui"
        "board"
    REQUIRES
        # The native USB port — the protocol link. NOT TinyUSB: the ESP32-S3's own USB-Serial-JTAG
        # peripheral already presents a CDC interface, so there is nothing to compose. See panel_link.c.
        esp_driver_usb_serial_jtag
        esp_lcd
        esp_lcd_touch
        esp_io_expander
        esp_timer
        driver
        # Self-update: esp_ota_* writes the spare slot, esp_partition reads it back for the SHA-256, and
        # mbedtls computes it. Nothing here talks HTTP — the image arrives as 0x03 frames on the cable
        # that is already attached (docs/protocol.md §2).
        app_update
        esp_partition
        mbedtls
        # cJSON, via ram_telemetry.c's PSRAM-first allocator hooks. Installed at the top of app_main so
        # it is in place before the first parse, not merely before the first message.
        json
        lvgl
)

# snprintf() is bounded (it truncates, never overflows), but -O2 turns on a format-truncation analysis
# that errors on safe same-size copies. Keep it a warning, not an error.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-format-truncation)
