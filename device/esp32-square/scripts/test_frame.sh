#!/usr/bin/env bash
# Compile and run the framing codec's host test.
#
# The codec is deliberately free of ESP-IDF so this runs on a laptop in
# milliseconds instead of on the device through a flash cycle — which is the
# only reason it is practical to run it on every change.
#
# The Dart half of the same link is checked against the SAME vector file:
#   flutter test test/panel/          (from the repo root)
#
# Usage: ./scripts/test_frame.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/test_panel_frame"

cc -std=c99 -Wall -Wextra -Wpedantic -O1 \
    "$HERE/test/test_panel_frame.c" \
    "$HERE/main/panel_frame.c" \
    -o "$OUT"

"$OUT" "$HERE/test/vectors/panel_frame.txt"
