The device's firmware image lives here as `grid_panel.bin`, and it is **tracked**.
The app offers it to any panel reporting a different version
(`docs/panel-protocol.md`, §2 "Firmware update").

It is tracked because nothing else puts it in a release. CI runs no ESP-IDF and
copies no image, so while this file was gitignored every shipped DMG carried
none — and a panel that disagreed with it about the protocol sat on "Panel needs
an update — Grid can reflash it over this cable" forever, in front of an app
that had nothing to reflash with. Building the firmware in CI is the better
answer and the one that lets this go back to being ignored.

⚠️ **It is a build output kept by hand, which is the risk that comes with the
fix.** `scripts/sync_panel_firmware.sh` copies it out of `device/esp32-circle/
build/`, and nothing checks that what is committed here matches `PROJECT_VER` in
that directory's `CMakeLists.txt`. A firmware change committed without re-running
the sync ships the *previous* image under the *new* version's name — and the app
compares versions, so the mismatch would never be offered and never be noticed.
Re-run the sync in the same commit that bumps the version.

The image must be a real ESP-IDF application image; the app reads the version out
of its `esp_app_desc_t` rather than from anything written down beside it, so
there is nothing here to keep in step by hand.
