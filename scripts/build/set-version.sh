#!/usr/bin/env bash
# Stamp the app version (from the pushed git tag) into pubspec.yaml.
#
# Releases are tag-triggered (.github/workflows/release.yml): CI runs this with
# the pushed tag so the built app's version always matches the git tag — no
# hand-edited "bump version" commit required. Flutter propagates pubspec's
# `version:` into the macOS Info.plist (CFBundleShortVersionString) and the
# Windows Runner.rc (FLUTTER_VERSION), so this single edit covers every platform.
#
# Usage:
#   set-version.sh 0.1.2      # explicit
#   set-version.sh v0.1.2     # a leading "v" is stripped
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBSPEC="${REPO_ROOT}/pubspec.yaml"

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [ -z "${VERSION}" ]; then
  echo "set-version: no version given (usage: set-version.sh v0.1.2)" >&2
  exit 1
fi

# Flutter's version is plain semver with an optional `+build` suffix (x.y.z[+b]).
if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$'; then
  echo "set-version: '${VERSION}' is not a valid Flutter version (x.y.z[+build])" >&2
  exit 1
fi

# Rewrite the single top-level `version:` line. No `sed -i` — its flags differ
# between BSD/macOS and GNU/git-bash (Windows runners) — so write to a temp file
# and move it back, which is portable across all three CI platforms.
tmp="$(mktemp)"
sed "s/^version: .*/version: ${VERSION}/" "${PUBSPEC}" > "${tmp}"
mv "${tmp}" "${PUBSPEC}"

echo "set-version: stamped ${VERSION}"
grep '^version:' "${PUBSPEC}"
