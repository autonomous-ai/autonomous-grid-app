#!/usr/bin/env bash
# Bundle the standalone `grid` CLI into the macOS app as a sidecar.
#
# Builds the Nuitka onefile binary via scripts/cli/build_sidecar.sh, then drops it
# into `Grid.app/Contents/Resources/grid` where GridResolver looks for it first.
#
# Nuitka cannot cross-compile: run this on the target arch (Apple Silicon).
# For real distribution, replace the ad-hoc signing below with a Developer ID
# signature + notarization (a bundled, unsigned binary trips Gatekeeper).
#
# Usage:  ./scripts/bundle_grid_macos.sh [path-to-cli-source]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# CLI source: explicit arg wins; else the first sibling that looks like the CLI repo.
CLI_REPO="${1:-}"
if [ -z "$CLI_REPO" ]; then
  for c in "$APP_ROOT/../autonomous-grid" "$APP_ROOT/../autonomous-grid-cli"; do
    [ -d "$c" ] && { CLI_REPO="$c"; break; }
  done
fi
if [ -z "$CLI_REPO" ] || [ ! -d "$CLI_REPO" ]; then
  echo "ERROR: CLI source not found (pass it as arg 1)" >&2
  exit 1
fi
GRID_BIN="$CLI_REPO/dist/grid"

if [ ! -x "$GRID_BIN" ] || [ "${REBUILD:-0}" = "1" ]; then
  echo ">>> Building standalone grid binary (Nuitka)…"
  "$APP_ROOT/scripts/cli/build_sidecar.sh" "$CLI_REPO"
fi

echo ">>> Building macOS app (flutter build macos --release)…"
(cd "$APP_ROOT" && flutter build macos --release)

APP_BUNDLE="$(find "$APP_ROOT/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1)"
if [ -z "$APP_BUNDLE" ]; then
  echo "ERROR: built .app not found under build/macos/.../Release" >&2
  exit 1
fi

RES_DIR="$APP_BUNDLE/Contents/Resources"
echo ">>> Copying grid → $RES_DIR/grid"
cp "$GRID_BIN" "$RES_DIR/grid"
chmod +x "$RES_DIR/grid"

echo ">>> Ad-hoc signing (replace with Developer ID + notarization for release)…"
codesign --force --sign - "$RES_DIR/grid"
codesign --force --deep --sign - "$APP_BUNDLE"

echo
echo "Bundled. Sidecar at: $RES_DIR/grid"
echo "App: $APP_BUNDLE"
