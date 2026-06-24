#!/usr/bin/env bash
# CI-only: prepare a fresh macOS runner for Developer ID signing + notarization
# so the existing scripts/notarize_macos.sh works unchanged. A hosted runner has
# no Developer ID cert and no stored notary profile, which that script assumes —
# this bridges the gap: it imports the cert into a throwaway keychain (made the
# default so codesign + notarytool both find it) and stores notarytool creds
# under a named profile. Everything comes from env (GitHub Secrets); no prompts.
#
# Required env (set from secrets in the workflow):
#   APPLE_CERTIFICATE_BASE64    base64 of the "Developer ID Application" .p12
#   APPLE_CERTIFICATE_PASSWORD  password used when exporting that .p12
#   APPLE_ID                    Apple ID email          (notarytool)
#   APPLE_TEAM_ID               Apple Developer Team ID (notarytool)
#   APPLE_APP_PASSWORD          app-specific password   (notarytool)
# Optional env:
#   NOTARY_PROFILE              keychain profile name (default: grid-notary)
set -euo pipefail

: "${APPLE_CERTIFICATE_BASE64:?set APPLE_CERTIFICATE_BASE64}"
: "${APPLE_CERTIFICATE_PASSWORD:?set APPLE_CERTIFICATE_PASSWORD}"
: "${APPLE_ID:?set APPLE_ID}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
: "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"
NOTARY_PROFILE="${NOTARY_PROFILE:-grid-notary}"

# Ephemeral, local-only password for a keychain that dies with the runner.
KEYCHAIN_PASSWORD="ci-keychain-$$"
KEYCHAIN="${RUNNER_TEMP:-/tmp}/grid-signing.keychain-db"

echo ">>> Creating temporary keychain"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings -lut 3600 "${KEYCHAIN}"   # auto-relock after 1h
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"

# Make it the DEFAULT keychain and first in the search list, so both
# `codesign --sign` (notarize_macos.sh) and `notarytool` resolve against it
# without either needing an explicit --keychain flag.
security default-keychain -s "${KEYCHAIN}"
security list-keychains -d user -s "${KEYCHAIN}" \
  $(security list-keychains -d user | sed 's/["[:space:]]//g')

echo ">>> Importing Developer ID certificate"
CERT="${RUNNER_TEMP:-/tmp}/grid-cert.p12"
echo "${APPLE_CERTIFICATE_BASE64}" | base64 --decode > "${CERT}"
security import "${CERT}" -k "${KEYCHAIN}" -P "${APPLE_CERTIFICATE_PASSWORD}" \
  -T /usr/bin/codesign -T /usr/bin/security
rm -f "${CERT}"

# Allow codesign to use the private key non-interactively.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null

echo ">>> Storing notarytool credentials as profile '${NOTARY_PROFILE}'"
xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${APPLE_TEAM_ID}" \
  --password "${APPLE_APP_PASSWORD}"

echo ">>> Codesigning identities now available:"
security find-identity -v -p codesigning "${KEYCHAIN}"
