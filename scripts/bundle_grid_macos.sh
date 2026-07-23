#!/usr/bin/env bash
# Bundle the standalone `grid` CLI into the macOS app as a sidecar.
#
# Builds the Nuitka standalone/onedir folder via scripts/cli/build_sidecar.sh, then
# drops it into `Grid.app/Contents/Resources/grid/` (entry exe Resources/grid/grid)
# where GridResolver looks for it first. Onedir (not onefile) so nothing is extracted
# at runtime — an onefile payload is SIGKILL'd by macOS under download quarantine.
#
# Nuitka cannot cross-compile: run this on the target arch (Apple Silicon).
# For real distribution, replace the ad-hoc signing below with a Developer ID
# signature + notarization (a bundled, unsigned binary trips Gatekeeper).
#
# Usage:  ./scripts/bundle_grid_macos.sh [path-to-cli-source]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# CLI source: explicit arg wins; else the sibling clone of the CLI repo. One name
# only — see build_sidecar.sh: a leftover clone under the repo's old name would
# otherwise be compiled into the app in place of the real source.
CLI_REPO="${1:-$APP_ROOT/../autonomous-grid}"
if [ -z "$CLI_REPO" ] || [ ! -d "$CLI_REPO" ]; then
  echo "ERROR: CLI source not found (pass it as arg 1)" >&2
  exit 1
fi
GRID_DIST="$CLI_REPO/dist/grid.dist"

if [ ! -x "$GRID_DIST/grid" ] || [ "${REBUILD:-0}" = "1" ]; then
  echo ">>> Building standalone grid folder (Nuitka onedir)…"
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
echo ">>> Copying grid.dist/ → $RES_DIR/grid/"
rm -rf "$RES_DIR/grid"
cp -R "$GRID_DIST" "$RES_DIR/grid"
chmod +x "$RES_DIR/grid/grid"

echo ">>> Ad-hoc signing (replace with Developer ID + notarization for release)…"
codesign --force --sign - "$RES_DIR/grid/grid"
codesign --force --deep --sign - "$APP_BUNDLE"

echo
echo "Bundled. Sidecar at: $RES_DIR/grid/grid"
echo "App: $APP_BUNDLE"
