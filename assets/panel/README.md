Put the device's firmware image here as `grid_panel.bin`, and the app will offer
it to any panel reporting a different version (`docs/panel-protocol.md`, §2
"Firmware update").

This directory is declared in `pubspec.yaml` and must not be deleted: Flutter
fails the build outright on a declared asset directory that does not exist. It
is empty on purpose — `panelFirmwareProvider` treats a missing image as "carry
none", logs it once and never offers an update, which is the correct behaviour
for a checkout with no device attached to it.

The image must be a real ESP-IDF application image; the app reads the version
out of its `esp_app_desc_t` rather than from anything written down beside it,
so there is nothing here to keep in step.
