#!/usr/bin/env bash
# Copies the built panel firmware into the app's assets.
#
#   scripts/sync_panel_firmware.sh
#
# The app carries the image its own build was compiled against so the two halves
# cannot drift: on `hello` it compares what the panel reports with what it is
# carrying and offers to fix a mismatch over the same cable (device/esp32-square
# /docs/protocol.md §2, "Firmware update").
#
# Why a copy rather than an asset line pointing straight at the build tree:
# `device/esp32-square/build/` is gitignored — an ESP-IDF build tree is tens of
# thousands of files — and a declared asset that is missing fails the Flutter
# build outright. That would break `flutter run` for everyone who has never
# flashed a panel, which is most people working on this app.
#
# Nothing here records a version. The image states its own inside
# `esp_app_desc_t`, and that is what the app reads (panel_firmware.dart); a
# version written down beside the bytes is a version that can disagree with
# them, and this one would disagree silently.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="device/esp32-square/build/grid_panel.bin"
DST="assets/panel/grid_panel.bin"

if [ ! -f "$SRC" ]; then
  echo "no $SRC — build it first: cd device/esp32-square && idf.py build" >&2
  exit 1
fi

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"

# Printed rather than stored: it is what the panel is offered, and seeing it
# here is how you check the copy is the build you meant.
python3 - "$DST" <<'PY'
import hashlib, sys

image = open(sys.argv[1], 'rb').read()
# esp_image_header_t (24) + esp_image_segment_header_t (8) = esp_app_desc_t,
# whose version[32] sits 16 bytes into it.
version = image[48:80].split(b'\x00')[0].decode('ascii', 'replace')
print(f'{sys.argv[1]}: version {version}, {len(image)} bytes, '
      f'sha256 {hashlib.sha256(image).hexdigest()}')
PY
