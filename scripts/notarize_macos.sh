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
SIDECAR="$APP/Contents/Resources/grid"

[ -d "$APP" ] || { echo "App not found: $APP — build it first." >&2; exit 1; }

# Sign inside-out: nested binaries first, then the app bundle. Hardened runtime
# (--options runtime) + a secure timestamp are mandatory for notarization.
if [ -f "$SIDECAR" ]; then
  echo ">>> Signing bundled grid sidecar…"
  # The grid sidecar is a Nuitka onefile: it unpacks + execs a payload at run
  # time, so under hardened runtime it needs these relaxations. If notarization
  # still flags it, add allow-unsigned-executable-memory / allow-jit here.
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$SIDECAR"
fi

echo ">>> Signing app bundle (hardened runtime)…"
codesign --force --options runtime --timestamp --deep \
  --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ">>> Building DMG…"
"$APP_ROOT/scripts/package_dmg_macos.sh" "$APP" "$OUT_DMG"

echo ">>> Notarizing (a few minutes)…"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo ">>> Stapling the ticket…"
xcrun stapler staple "$OUT_DMG"
xcrun stapler staple "$APP"

echo ">>> Gatekeeper assessment:"
spctl -a -t open --context context:primary-signature -vv "$OUT_DMG" || true
echo "Done → $OUT_DMG"
