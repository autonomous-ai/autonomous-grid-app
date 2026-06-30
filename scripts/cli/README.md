# `grid` CLI sidecar build drivers

grid-app drives the `grid` CLI as a subprocess. The CLI is a Python package, so we
ship a **Nuitka onefile binary** rather than the source. These scripts are grid-app's
**own** build drivers — they compile the CLI *source* (cloned separately) into a single
self-contained binary, so we control the build (including the Windows target) **without
modifying the CLI repo** (`autonomous-ai/autonomous-grid`).

| Script | Platform | Output |
|--------|----------|--------|
| `build_sidecar.sh`  | macOS / Linux | `<cli-src>/dist/grid` |
| `build_sidecar.ps1` | Windows x64   | `<cli-src>\dist\grid.exe` |
| `grid_entry.py`     | (shared)      | Nuitka entry — mirrors the CLI's `cli/__main__.py` |

Nuitka **cannot cross-compile** — each target is built on its own arch/OS (that's why
the release matrix runs one job per platform).

## How it works

1. Take the CLI source path (arg / `-CliSrc`, or autodetect a sibling `autonomous-grid`).
2. Create an isolated `.venv-build` beside the CLI source, `pip install` the CLI + Nuitka.
3. Discover the CLI's first-party packages (top-level dirs with `__init__.py`) and
   force-follow them — the CLI imports heavy deps lazily, so this avoids missing modules.
   New upstream packages are picked up automatically (no hardcoded list to drift).
4. Compile `grid_entry.py` into a onefile binary.

## Local use

```bash
# macOS — native arm64 needs an arm64 python (e.g. the python.org universal2 build):
GRID_BUILD_PYTHON=/usr/local/bin/python3.13 scripts/cli/build_sidecar.sh ../autonomous-grid
# -> ../autonomous-grid/dist/grid   (point the app at it with GRID_BIN, see ../README.md)
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\cli\build_sidecar.ps1 -CliSrc ..\autonomous-grid
```

CI calls these from `.github/workflows/release.yml` and injects the result as the app
sidecar. The binary is **not committed** (per-platform, ~tens of MB).
