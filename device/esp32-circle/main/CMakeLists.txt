# Single "main" component holding every source. Board drivers live under board/, the LVGL UI under ui/.
#
# panel_frame.c is listed here AND compiled separately by ../scripts/test_frame.sh with a plain host
# compiler. That is why it must stay free of ESP-IDF headers: the moment it includes one, the host test
# stops building and the only cheap check on the wire format goes with it.
idf_component_register(
    SRCS
        "app_main.c"
        "audio_capture.c"
        "buttons.c"
        "device_mac.c"
        "device_prefs.c"
        "fw_update.c"
        "panel_client.c"
        "panel_frame.c"
        "panel_link.c"
        "ram_telemetry.c"
        "voice.c"
        "board/board_i2c.c"
        "board/power.c"
        "ui/display.c"
        "ui/touch.c"
        "ui/ui_screens.c"
        # Fonts and icons: generated C arrays, lifted whole from the reference firmware.
        #
        # Listing all of them costs build time and NOT flash — each is its own object file in libmain.a,
        # so the linker only pulls in the ones something actually names.
        #
        # They are all here because regenerating one later needs the .ttf, the LVGL font converter and the
        # exact glyph ranges. The .ttf files are vendored under fonts/ (Geist is OFL 1.1, which permits it)
        # and the invocation is in the `Opts:` header inside each generated file.
        "ui/geist_reg_16.c"
        "ui/geist_reg_20.c"
        "ui/geist_reg_24.c"
        "ui/geist_reg_25.c"
        "ui/geist_reg_32.c"
        "ui/geist_reg_34.c"
        "ui/geist_reg_38.c"
        "ui/geist_med_28.c"
        "ui/geist_med_32.c"
        "ui/geist_med_38.c"
        "ui/geist_med_48.c"
        "ui/geist_sem_24.c"
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
        esp_codec_dev
        esp_timer
        driver
        # Self-update: esp_ota_* writes the spare slot, esp_partition reads it back for the SHA-256, and
        # mbedtls computes it. Nothing here talks HTTP — the image arrives as 0x03 frames on the cable
        # that is already attached (docs/panel-protocol.md §2, "Firmware update").
        app_update
        esp_partition
        mbedtls
        # cJSON, via ram_telemetry.c's PSRAM-first allocator hooks. Installed at the top of app_main so
        # it is in place before the first parse, not merely before the first message.
        json
        lvgl
        # The one preference the device owns — its own screen brightness (device_prefs.c). NVS rather than
        # a file: there is no filesystem here, and a key-value store is the whole need.
        nvs_flash
)

# snprintf() is bounded (it truncates, never overflows), but -O2 turns on a format-truncation analysis
# that errors on safe same-size copies. Keep it a warning, not an error.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-format-truncation)
