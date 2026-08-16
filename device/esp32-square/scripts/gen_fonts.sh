#!/bin/bash
# Regenerate the device's Geist faces — one per (weight, size) the UI actually uses.
#
# The TTFs are VENDORED under fonts/ rather than read from the system. Geist is SIL OFL 1.1, which permits
# embedding and redistribution, so anyone who clones this repo can rebuild the fonts.
#
# RANGE is what Geist supplies. FB is filled from Arial Unicode and is computed as
#   (the ranges this firmware builds) MINUS (what Geist has), INTERSECTED with (what Arial has)
# so the two blocks are disjoint and font precedence never matters.
#
# 0x2713 (check) and 0x2717 (cross) sit in FB, NOT in RANGE: Geist has neither, and they belong to no
# contiguous block, so they are the easiest thing here to lose. Losing them once already turned the
# selected-machine tick into an empty box. If you touch the ranges, re-run the coverage check.
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"
FB=0x00AD,0x0114-0x0115,0x012C-0x012D,0x0138,0x013F-0x0140,0x0149,0x014E-0x014F,0x017F-0x018E,0x0190-0x0191,0x0193-0x019F,0x01A2-0x01AE,0x01B1-0x01CC,0x01CF-0x01E3,0x01EA-0x01F5,0x01FA-0x0217,0x1E00-0x1E1F,0x1E22-0x1E7F,0x1E86-0x1E9B,0x2015-0x2017,0x201B,0x201F,0x2023-0x2025,0x2713,0x2717
REG=fonts/Geist-Regular.ttf
MED=fonts/Geist-Medium.ttf
SEM=fonts/Geist-SemiBold.ttf
ARIAL="/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
RANGE=0x20-0x7F,0xA0-0x24F,0x1E00-0x1EFF,0x2013-0x2026,0x203A
gen() {  # gen <src> <tag> <size>
  local out="main/ui/geist_$2_$3.c"
  [ -s "$out" ] && { echo "  skip $out"; return; }
  npx --yes lv_font_conv@1.5.3 --bpp 4 --size "$3" --format lvgl --no-compress --no-prefilter \
    --font "$1" --range "$RANGE" --font "$ARIAL" --range "$FB" \
    -o "$out" --lv-include lvgl.h
  printf "  %-26s %6.0f KB\n" "$out" "$(($(stat -f%z "$out")/1024))"
}
# SIZES ARE THE 720px BOARD'S, SCALED BY 0.667 — the same factor the layout was scaled by.
#
# This UI came from the 720x720 board and every box in it was multiplied by 0.667 for a 480px panel. The
# type was not: it kept the round board's sizes, which were drawn against that board's much taller bands.
# The result was a whole UI of text too big for its own boxes — a 41px Overview row holding a font whose
# line height is 35px, an agent count needing 65px in an 81px gap. So the faces below finish the job:
#
#   720px face      x0.667   face here
#   roboto_reg_20   13.3     geist_reg_13
#   roboto_reg_25   16.7     geist_reg_16
#   roboto_reg_35   23.3     geist_reg_24
#   roboto_reg_38   25.3     geist_reg_25
#   roboto_med_32   21.3     geist_med_21
#   roboto_med_38   25.3     geist_med_25
#   roboto_med_56   37.3     geist_med_38
#   roboto_med_92   61.3     geist_med_56   (61 would need 82px of line height for an 81px slot)
#
# 20/32/34/48 stay generated for now; drop them from main/CMakeLists.txt once nothing references them.
for s in 13 16 24 25; do gen "$REG" reg "$s"; done
for s in 21 25;       do gen "$MED" med "$s"; done

# The Overview agent count is DIGITS AND NOTHING ELSE, and at 56px a full Vietnamese face costs ~3MB of
# generated source (and the flash to match). Build this one over 0x30-0x39 only — the same reason the
# 720px board noted "DIGITS ONLY" beside its 92px face.
gen_digits() {
  local out="main/ui/geist_${2}_${3}.c"
  [ -s "$out" ] && { echo "  skip $out"; return; }
  npx --yes lv_font_conv@1.5.3 --bpp 4 --size "$3" --format lvgl --no-compress --no-prefilter \
    --font "$1" --range 0x30-0x39 \
    -o "$out" --lv-include lvgl.h
  printf "  %-26s %6.0f KB  (digits only)\n" "$out" "$(($(stat -f%z "$out")/1024))"
}
gen_digits "$MED" med 56
# No SemiBold here. The round board uses one for the reset-confirm primary; this UI came from the 720px
# board, which does not, so generating it would be 700KB of source nothing references.
echo "xong"
