# Top-level ESP-IDF project file for the Grid panel.
#
# Board: Waveshare ESP32-S3-Touch-AMOLED-1.75 — ESP32-S3R8, 466x466 round AMOLED over QSPI (CO5300),
# CST9217 touch (mounted 180 degrees to the panel), 16 MB flash, 8 MB octal PSRAM, ES8311 codec.
#
# Requires ESP-IDF >= 5.5. Build with:
#     source ~/esp/esp-idf/export.sh
#     idf.py set-target esp32s3 && idf.py build
#
# The framing codec (main/panel_frame.c) is also compiled by ./scripts/test_frame.sh with a plain host
# compiler, which is why it contains no ESP-IDF: it is checked against the same vectors as the Dart half
# on a laptop in milliseconds, instead of on the device through a flash cycle.
cmake_minimum_required(VERSION 3.16)

# ── Keep sdkconfig honest about sdkconfig.defaults ───────────────────────────────────────────────────
# ESP-IDF reads sdkconfig.defaults ONLY when creating sdkconfig. After that sdkconfig is authoritative and
# the defaults are ignored outright — no merge, no warning. That is deliberate (so `idf.py menuconfig`
# edits survive), but it means the file we track states the intent while the file we gitignore decides
# the build.
#
# Lifted from the reference firmware, where that gap cost two weeks: a commit raised the main task stack,
# moved BSS to PSRAM and re-shaped the LVGL pool, and every build on a checkout whose sdkconfig predated
# it silently kept the old values — surfacing eventually as published firmware that overflowed its stack
# mid-update and could never fix itself.
#
# It matters more here, not less. CONFIG_ESP_CONSOLE_SECONDARY_NONE is the line that keeps the console
# out of the protocol stream (see sdkconfig.defaults); a stale sdkconfig silently puts it back, and the
# symptom is a link that connects and then delivers log text forever.
#
# So: stamp the hash of sdkconfig.defaults beside sdkconfig. When they disagree, move sdkconfig aside and
# let IDF re-seed it. Day-to-day menuconfig still works; a pull that changes defaults re-applies itself.
# A deliberate local tweak belongs in sdkconfig.defaults, where it is reviewable and reaches everyone.
set(_sdkcfg "${CMAKE_CURRENT_LIST_DIR}/sdkconfig")
set(_defaults "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults")
set(_stamp "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults.stamp")
if(EXISTS "${_defaults}")
    # Re-run THIS check whenever sdkconfig.defaults changes. Without it the guard has a hole big enough
    # to drive the bug through: CMake only re-configures when a file it is watching changes, and it does
    # not watch sdkconfig.defaults on its own — so editing the defaults and typing `idf.py build` skipped
    # the check entirely and built the stale config, silently.
    #
    # Found the way these things are always found: a debug option was removed from sdkconfig.defaults, the
    # build said "complete", and the generated sdkconfig still had it set. The guard was written for
    # exactly that and could not fire.
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_defaults}")
    file(SHA256 "${_defaults}" _defaults_hash)
    set(_prev_hash "")
    if(EXISTS "${_stamp}")
        file(READ "${_stamp}" _prev_hash)
        string(STRIP "${_prev_hash}" _prev_hash)
    endif()
    if(EXISTS "${_sdkcfg}" AND NOT _prev_hash STREQUAL _defaults_hash)
        message(WARNING
            "sdkconfig.defaults changed since this sdkconfig was generated -- regenerating it.\n"
            "Any local `idf.py menuconfig` tweak not present in sdkconfig.defaults is being discarded; "
            "put it in sdkconfig.defaults if it should survive.\n"
            "Previous config saved as sdkconfig.superseded.")
        file(RENAME "${_sdkcfg}" "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.superseded")
    endif()
    file(WRITE "${_stamp}" "${_defaults_hash}")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# ── THE FIRMWARE VERSION, and why it is stated here ─────────────────────────────────────────────────
# IDF stamps PROJECT_VER into the image's esp_app_desc_t. Set it BEFORE project(), which is where that
# is read, and this is the ONLY place it is written down: main/panel_client.c reports what it finds in
# the running image rather than a constant of its own, and app_main logs the same call.
#
# ⚠️ WITHOUT this line IDF falls back to `git describe`, and that fallback is not a version — it moves on
# every commit and gains "-dirty" from any uncommitted file. grid-app decides whether to offer an update
# by comparing the version in `hello` against the one inside the .bin it carries, so a describe string
# would make the two disagree on almost every build: the app would offer to reflash a panel that is
# already running the identical image, at every plug, forever. Found on the app side before either half
# had ever run the update path.
#
# Bump this on a release. It is the string a person reads off the panel and the string the app compares.
set(PROJECT_VER "0.1.5")

project(grid_panel)
