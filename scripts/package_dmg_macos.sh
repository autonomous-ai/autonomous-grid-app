#!/usr/bin/env bash
# Package the built macOS app into a drag-to-install .dmg (app + Applications
# symlink). Run AFTER scripts/bundle_grid_macos.sh so the sidecar is inside.
#
#   ./scripts/package_dmg_macos.sh [path-to-.app] [output.dmg]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$(find "$APP_ROOT/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n1)}"
OUT="${2:-$HOME/Desktop/grid_app-0.1.0-macos.dmg}"
VOLNAME="${VOLNAME:-Grid}"

[ -d "$APP" ] || { echo "App not found: $APP — build it first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

echo "DMG: $OUT ($(du -h "$OUT" | cut -f1))"
