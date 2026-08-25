#!/usr/bin/env bash
# Package the built Linux app into a portable .tar.gz (bundle + `grid` sidecar).
#
# Run AFTER `flutter build linux --release` and after the Nuitka sidecar is built
# (scripts/cli/build_sidecar.sh). The sidecar goes in as a `grid/` folder beside
# the app binary, because that is where GridResolver._bundledCandidates looks on
# Linux (`$exeDir/grid/grid`). Same onedir shape macOS ships under
# Contents/Resources/grid, and for one of the same reasons: the helper travels
# inside the thing the user downloaded instead of being fetched later.
#
# No signing and no repository packaging (.deb/AppImage) — a tarball the user
# unpacks and runs is the honest floor, and it is what the app's own resolver
# already understands. Anything richer is a decision to take deliberately.
#
#   ./scripts/package_linux.sh [path-to-bundle] [output.tar.gz]
#   SIDECAR=../autonomous-grid/dist/grid.dist ./scripts/package_linux.sh
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$APP_ROOT/build/linux/x64/release/bundle}"
OUT="${2:-$HOME/grid_app-linux-x64.tar.gz}"
SIDECAR="${SIDECAR:-$APP_ROOT/../autonomous-grid/dist/grid.dist}"
# What the tarball unpacks into, so it never spills loose files into a download
# folder. Matches BINARY_NAME's product, not the binary itself.
TOPDIR="${TOPDIR:-Grid}"

[ -d "$BUNDLE" ] || {
  echo "Bundle not found: $BUNDLE — run 'flutter build linux --release' first." >&2
  exit 1
}
[ -x "$BUNDLE/grid_app" ] || {
  echo "App binary not found: $BUNDLE/grid_app (linux/CMakeLists.txt BINARY_NAME)" >&2
  exit 1
}
[ -x "$SIDECAR/grid" ] || {
  echo "Sidecar not found: $SIDECAR/grid — run scripts/cli/build_sidecar.sh first." >&2
  exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUNDLE" "$STAGE/$TOPDIR"
rm -rf "$STAGE/$TOPDIR/grid"
cp -R "$SIDECAR" "$STAGE/$TOPDIR/grid"
chmod +x "$STAGE/$TOPDIR/grid/grid" "$STAGE/$TOPDIR/grid_app"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
tar -C "$STAGE" -czf "$OUT" "$TOPDIR"

echo "tar.gz: $OUT ($(du -h "$OUT" | cut -f1))"
