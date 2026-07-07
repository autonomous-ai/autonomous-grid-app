#!/usr/bin/env bash
# Sign with Developer ID + notarize + staple the macOS app, then build a
# notarized .dmg. Produces a build that opens cleanly on any Mac (no Gatekeeper
# prompt). Requires credentials that an ad-hoc build does not — see below.
#
# ── One-time prerequisites ────────────────────────────────────────────────────
# 1. A "Developer ID Application" certificate in your login keychain. A team
#    Account Holder/Admin creates it at developer.apple.com → Certificates →
#    "Developer ID Application", then you download + double-click to install.
#    Verify:  security find-identity -v -p codesigning | grep "Developer ID"
#    (NOTE: "Apple Development" certs do NOT work — notarization rejects them.)
#
# 2. Stored notary credentials (pick one):
#    a) App Store Connect API key (recommended):
#         xcrun notarytool store-credentials grid-notary \
#           --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
#    b) Apple ID + app-specific password:
#         xcrun notarytool store-credentials grid-notary \
#           --apple-id you@apple.id --team-id TEAMID --password APP-SPECIFIC-PW
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   DEV_ID="Developer ID Application: Your Co (TEAMID)" \
#   NOTARY_PROFILE=grid-notary \
#   ./scripts/notarize_macos.sh [path-to-.app]
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$(find "$APP_ROOT/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n1)}"
: "${DEV_ID:?Set DEV_ID to your 'Developer ID Application: …' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-grid-notary}"
ENTITLEMENTS="$APP_ROOT/macos/Runner/Release.entitlements"
OUT_DMG="${OUT_DMG:-$HOME/Desktop/grid_app-0.1.0-macos.dmg}"
SIDECAR_DIR="$APP/Contents/Resources/grid"   # Nuitka standalone (onedir) folder

[ -d "$APP" ] || { echo "App not found: $APP — build it first." >&2; exit 1; }

# Sign inside-out: nested binaries first, then the app bundle. Hardened runtime
# (--options runtime) + a secure timestamp are mandatory for notarization.
#
# The grid sidecar ships as a Nuitka *standalone/onedir* folder (Resources/grid/,
# entry at Resources/grid/grid). Sign EVERY Mach-O in it — libraries first, the
# entry exe last — so nothing is unsigned when notarytool inspects it. Onedir
# replaces the old --onefile sidecar whose runtime-extracted payload macOS
# SIGKILL'd under download quarantine (the app's preflight then reported the
# helper as blocked). The app --deep pass below re-seals these into CodeResources.
if [ -d "$SIDECAR_DIR" ]; then
  echo ">>> Signing bundled grid sidecar (Nuitka onedir)…"
  # Every Mach-O gets the same Developer ID, so onedir's sibling .so/.dylib all
  # satisfy library validation — no need for disable-library-validation/JIT
  # entitlements (those were only for the old onefile's extracted payload).
  while IFS= read -r -d '' f; do
    [ "$f" = "$SIDECAR_DIR/grid" ] && continue          # entry exe signed last
    file -b "$f" | grep -q 'Mach-O' || continue          # skip data/text files
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$f"
  done < <(find "$SIDECAR_DIR" -type f -print0)
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$SIDECAR_DIR/grid"
  codesign --verify --verbose=2 "$SIDECAR_DIR/grid" || { echo "ERROR: sidecar signature invalid" >&2; exit 1; }
fi

echo ">>> Signing app bundle (hardened runtime)…"
codesign --force --options runtime --timestamp --deep \
  --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Two passes so BOTH the app and the dmg end up stapled (offline-ready):
# 1) notarize + staple the app, 2) build the dmg from the stapled app, then
# notarize + staple the dmg. Stapling the app before packaging is the only way
# the dmg's copy carries a ticket (a rebuilt dmg is a fresh, un-notarized file).
echo ">>> Notarizing the app (a few minutes)…"
APP_ZIP="$(dirname "$APP")/notarize-app.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$APP_ZIP"
xcrun stapler staple "$APP"

echo ">>> Building DMG from the stapled app…"
"$APP_ROOT/scripts/package_dmg_macos.sh" "$APP" "$OUT_DMG"

echo ">>> Notarizing the DMG (a few minutes)…"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT_DMG"

echo ">>> Gatekeeper assessment (app inside the dmg):"
MP="$(hdiutil attach "$OUT_DMG" -nobrowse 2>/dev/null | grep -o '/Volumes/.*' | head -1)"
spctl -a -t exec -vv "$MP/$(basename "$APP")" 2>&1 | head -3 || true
hdiutil detach "$MP" >/dev/null 2>&1 || true
echo "Done → $OUT_DMG"
