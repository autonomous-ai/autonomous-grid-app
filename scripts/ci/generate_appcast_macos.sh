#!/usr/bin/env bash
# Sign the notarized macOS DMG with the Sparkle EdDSA key and emit the appcast
# feed the app polls for updates (see lib/features/app_update/logic/
# app_updater_service.dart and the GRID_APPCAST_URL dart-define).
#
# Run from the grid-app dir AFTER `flutter build macos` so the Sparkle
# sign_update tool exists at macos/Pods/Sparkle/bin/sign_update (CocoaPods
# installs it during the build). `dart run auto_updater:sign_update` forwards its
# args straight to that tool.
#
# Required env:
#   DMG              path to the signed + notarized .dmg
#   DOWNLOAD_URL     public URL the .dmg will be served from (the enclosure href)
#   SHORT_VERSION    marketing version, e.g. 0.2.0   (CFBundleShortVersionString)
#   BUNDLE_VERSION   monotonic build number, e.g. 2000 (CFBundleVersion) — Sparkle
#                    compares this to decide "is there a newer build?"
#   APPCAST_OUT      output path for appcast.xml
# Optional env:
#   SPARKLE_ED_PRIVATE_KEY   base64 EdDSA private key (exported from
#                            `dart run auto_updater:generate_keys`). When empty
#                            the step is skipped so releases still build before
#                            the key is provisioned.
#   NOTES            plain-text release notes shown in Sparkle's update prompt.
set -euo pipefail

: "${DMG:?set DMG}"
: "${DOWNLOAD_URL:?set DOWNLOAD_URL}"
: "${SHORT_VERSION:?set SHORT_VERSION}"
: "${BUNDLE_VERSION:?set BUNDLE_VERSION}"
: "${APPCAST_OUT:?set APPCAST_OUT}"

if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  echo "::warning::SPARKLE_ED_PRIVATE_KEY not set — skipping appcast; macOS auto-update will not publish until the key is added."
  exit 0
fi

if [ ! -f "$DMG" ]; then
  echo "appcast: DMG not found at $DMG" >&2
  exit 1
fi

keyfile="$(mktemp)"
trap 'rm -f "$keyfile"' EXIT
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$keyfile"

# Sparkle's sign_update prints exactly: sparkle:edSignature="…" length="…"
sig_line="$(dart run auto_updater:sign_update "$DMG" --ed-key-file "$keyfile")"
case "$sig_line" in
  *edSignature=*) : ;;
  *)
    echo "appcast: sign_update did not return an EdDSA signature: $sig_line" >&2
    exit 1
    ;;
esac

pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
notes_block=""
if [ -n "${NOTES:-}" ]; then
  notes_block=$'      <description><![CDATA['"${NOTES}"$']]></description>\n'
fi

cat > "$APPCAST_OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Grid</title>
    <item>
      <title>Grid ${SHORT_VERSION}</title>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <pubDate>${pub_date}</pubDate>
${notes_block}      <enclosure url="${DOWNLOAD_URL}" sparkle:os="macos" ${sig_line} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "appcast: wrote $APPCAST_OUT"
cat "$APPCAST_OUT"
