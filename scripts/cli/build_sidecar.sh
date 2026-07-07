#!/usr/bin/env bash
# Build the standalone `grid` CLI sidecar (Nuitka standalone/onedir) for the CURRENT OS+arch.
#
# This is grid-app's OWN build driver: it compiles the grid CLI *source* (cloned
# separately, e.g. ../autonomous-grid) into a self-contained folder so the app can
# ship `grid` without the user installing Python/uv. Keeping the driver here — not in
# the CLI repo — lets us add a Windows path and tune Nuitka flags without touching the
# CLI repo (the Windows counterpart is scripts/cli/build_sidecar.ps1).
#
# ONEDIR, not --onefile: an onefile binary extracts an unsigned payload to a temp
# dir at runtime, which macOS SIGKILLs under download quarantine (the app's preflight
# then reports "Grid helper blocked"). A standalone/onedir folder ships all code inside
# the signed+notarized app bundle, so there's nothing to extract. See scripts/README.md.
#
# Nuitka CANNOT cross-compile: run it on the target arch (Apple Silicon for arm64).
# Output: <cli-src>/dist/grid.dist/  (entry exe at dist/grid.dist/grid) — where
# bundle_grid_macos.sh and release.yml inject from.
#
# Usage:
#   scripts/cli/build_sidecar.sh [path-to-cli-source]      # arg, or sibling autodetect
#   GRID_BUILD_PYTHON=python3.12 scripts/cli/build_sidecar.sh ../autonomous-grid
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # scripts/cli
APP_ROOT="$(cd "$HERE/../.." && pwd)"                  # grid-app repo root
ENTRY="$HERE/grid_entry.py"

# CLI source: explicit arg wins; else the first sibling that looks like the CLI repo.
CLI_SRC="${1:-}"
if [ -z "$CLI_SRC" ]; then
  for c in "$APP_ROOT/../autonomous-grid" "$APP_ROOT/../autonomous-grid-cli"; do
    [ -d "$c" ] && { CLI_SRC="$c"; break; }
  done
fi
[ -n "$CLI_SRC" ] && [ -d "$CLI_SRC" ] || { echo "ERROR: CLI source not found (pass it as arg 1)" >&2; exit 1; }
CLI_SRC="$(cd "$CLI_SRC" && pwd)"
[ -f "$CLI_SRC/pyproject.toml" ] || { echo "ERROR: $CLI_SRC has no pyproject.toml — not the grid CLI source?" >&2; exit 1; }

resolve_python() { "$1" -c 'import os, sys; print(os.path.realpath(sys.executable))'; }

# Prefer a real 3.11/3.12/3.13 interpreter. On Apple Silicon, GRID_BUILD_PYTHON pointing
# at a universal2/arm64 python (e.g. /usr/local/bin/python3.13) yields a native arm64
# binary; the default uv/brew python may be x86_64 and produce an x86_64 (Rosetta) build.
pick_python() {
  if [ -n "${GRID_BUILD_PYTHON:-}" ]; then
    command -v "$GRID_BUILD_PYTHON" >/dev/null 2>&1 || { echo "ERROR: GRID_BUILD_PYTHON not runnable: $GRID_BUILD_PYTHON" >&2; exit 1; }
    resolve_python "$(command -v "$GRID_BUILD_PYTHON")"; return
  fi
  for c in \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.13/bin/python3.13 \
    python3.11 python3.12 python3.13 python3
  do
    command -v "$c" >/dev/null 2>&1 && { resolve_python "$(command -v "$c")"; return; }
  done
  if command -v uv >/dev/null 2>&1; then
    for v in 3.11 3.12 3.13; do
      p="$(uv python find "$v" 2>/dev/null || true)"
      [ -n "$p" ] && [ -x "$p" ] && { resolve_python "$p"; return; }
    done
  fi
  echo "ERROR: need Python 3.11/3.12/3.13 (brew install python@3.12 or uv python install 3.12)" >&2; exit 1
}

BUILD_PY="$(pick_python)"
BUILD_VERSION="$("$BUILD_PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
case "$BUILD_VERSION" in 3.11|3.12|3.13) ;; *) echo "ERROR: build needs Python 3.11/3.12/3.13; got $BUILD_VERSION at $BUILD_PY" >&2; exit 1 ;; esac

case "$(uname -s)" in Darwin) OS_SUFFIX=macos ;; Linux) OS_SUFFIX=linux ;; *) OS_SUFFIX=unknown ;; esac

# Isolated build venv beside the CLI source (gitignored there). Rebuilt if its Python drifts.
BUILD_VENV="$CLI_SRC/.venv-build"
if [ -x "$BUILD_VENV/bin/python" ]; then
  VENV_VERSION="$("$BUILD_VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
  case "$VENV_VERSION" in 3.11|3.12|3.13) ;; *) echo ">>> Removing stale $BUILD_VENV"; rm -rf "$BUILD_VENV" ;; esac
fi
[ -x "$BUILD_VENV/bin/python" ] || { echo ">>> Creating build venv ($BUILD_PY)"; "$BUILD_PY" -m venv "$BUILD_VENV"; }
PY="$BUILD_VENV/bin/python"

echo ">>> Installing CLI source + Nuitka toolchain"
"$PY" -m pip install --upgrade pip >/dev/null
"$PY" -m pip install "$CLI_SRC" nuitka ordered-set zstandard

# First-party packages are discovered from the CLI source (top-level dirs with an
# __init__.py) so a package added upstream is followed automatically — no hardcoded
# drift. The CLI imports heavy deps lazily inside function bodies, so we force-follow
# every first-party package; uvicorn is third-party but lazily imported, so add it too.
INCLUDES=()
for d in "$CLI_SRC"/*/; do
  [ -f "${d}__init__.py" ] && INCLUDES+=("--include-package=$(basename "$d")")
done
[ ${#INCLUDES[@]} -gt 0 ] || { echo "ERROR: no first-party packages found in $CLI_SRC" >&2; exit 1; }
INCLUDES+=("--include-package=uvicorn")

echo ">>> Compiling with Nuitka (standalone onedir, $OS_SUFFIX): ${INCLUDES[*]}"
# --include-package-data bundles shared/media/workflows/*.json + shared/engine/*.txt;
# certifi ships the CA bundle httpx needs for TLS to the relay/control plane.
# NOTE: --standalone WITHOUT --onefile → a `<entry>.dist/` folder (no runtime
# extraction), so it survives macOS download quarantine once notarized.
( cd "$CLI_SRC" && "$PY" -m nuitka \
  --standalone \
  --deployment \
  --output-dir="$CLI_SRC/dist" \
  --output-filename=grid \
  --remove-output \
  --assume-yes-for-downloads \
  --company-name="LocalAGI" \
  --product-name="Grid CLI" \
  --product-version="0.1.0" \
  "${INCLUDES[@]}" \
  --include-package-data=shared \
  --include-package-data=certifi \
  "$ENTRY" )

# Nuitka names the standalone folder after the entry module (grid_entry.dist).
# Normalise to a stable dist/grid.dist/ with the entry exe at dist/grid.dist/grid,
# so bundle_grid_macos.sh and release.yml can inject from a predictable path.
rm -rf "$CLI_SRC/dist/grid.dist"
mv "$CLI_SRC/dist/grid_entry.dist" "$CLI_SRC/dist/grid.dist"

echo
echo "Built: $CLI_SRC/dist/grid.dist/  (entry exe: dist/grid.dist/grid)"
