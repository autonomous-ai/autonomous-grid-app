# `grid` CLI sidecar build drivers

grid-app drives the `grid` CLI as a subprocess. The CLI is a Python package, so we
ship a **Nuitka standalone (onedir) folder** rather than the source. These scripts are
grid-app's **own** build drivers — they compile the CLI *source* (cloned separately)
into a self-contained folder, so we control the build (including the Windows target)
**without modifying the CLI repo** (`autonomous-ai/autonomous-grid`).

Onedir, not `--onefile`: an onefile binary extracts an unsigned payload to a temp dir
at runtime, which macOS SIGKILLs under download quarantine (the app's preflight then
reports the helper as blocked). A onedir folder ships all code inside the signed +
notarized app bundle, so there's nothing to extract.

| Script | Platform | Output |
|--------|----------|--------|
| `build_sidecar.sh`  | macOS / Linux | `<cli-src>/dist/grid.dist/` (entry `dist/grid.dist/grid`) |
| `build_sidecar.ps1` | Windows x64   | `<cli-src>\dist\grid.exe` |
| `grid_entry.py`     | (shared)      | Nuitka entry — mirrors the CLI's `cli/__main__.py` |

Nuitka **cannot cross-compile** — the output arch follows the *build python's* arch, so
each target is built with a matching interpreter. The macOS Intel (x86_64) slice is built
on the Apple Silicon runner by feeding `build_sidecar.sh` an x86_64 python (via
`GRID_BUILD_PYTHON`), which runs under **Rosetta 2** — GitHub retired the free `macos-13`
Intel image, and this avoids a paid `-large` runner. That's why the release matrix has a
second `macos-latest` job (`arch: x64`).

## How it works

1. Take the CLI source path (arg / `-CliSrc`, or autodetect a sibling `autonomous-grid`).
2. Create an isolated `.venv-build` beside the CLI source, `pip install` the CLI + Nuitka.
3. Discover the CLI's first-party packages (top-level dirs with `__init__.py`) and
   force-follow them — the CLI imports heavy deps lazily, so this avoids missing modules.
   New upstream packages are picked up automatically (no hardcoded list to drift).
4. Compile `grid_entry.py` into a standalone (onedir) folder, normalised to
   `dist/grid.dist/` with the entry exe at `dist/grid.dist/grid`.

## Local use

```bash
# macOS — native arm64 needs an arm64 python (e.g. the python.org universal2 build):
GRID_BUILD_PYTHON=/usr/local/bin/python3.13 scripts/cli/build_sidecar.sh ../autonomous-grid
# -> ../autonomous-grid/dist/grid.dist/grid   (point the app at it with GRID_BIN, see ../README.md)
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\cli\build_sidecar.ps1 -CliSrc ..\autonomous-grid
```

CI calls these from `.github/workflows/release.yml` and injects the result as the app
sidecar. The binary is **not committed** (per-platform, ~tens of MB).
