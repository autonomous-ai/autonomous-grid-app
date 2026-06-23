# Bundling the `grid` CLI as a sidecar

The app drives the `grid` CLI as a subprocess. `GridResolver` finds it in this
order: **configured path → `GRID_BIN` env → bundled sidecar → `$PATH`**.

The CLI is a Python package, so we ship a **Nuitka onefile binary** (built by the
CLI repo's `build/build_{macos,linux,windows}` scripts) rather than the source.
The binary is **not committed** to this repo (it's ~tens of MB and per-platform) —
CI builds it and injects it at packaging time.

## Dev (`flutter run`)

No bundling. Use one of:

```bash
# Option A — install the CLI on PATH (resolver finds it last):
cd ../autonomous-grid-cli && uv tool install -e . --force

# Option B — point at a built binary without installing:
cd ../autonomous-grid-cli && ./build/build_macos.sh        # → dist/grid
export GRID_BIN="$PWD/dist/grid"
cd ../grid-app && flutter run -d macos
```

The app always drives the real `grid` — if it cannot be resolved, onboarding
shows "Grid CLI not found".

## Release (macOS)

```bash
./scripts/bundle_grid_macos.sh            # builds CLI + app, injects sidecar
# REBUILD=1 ./scripts/bundle_grid_macos.sh   # force-rebuild the CLI binary
```

This drops `grid` into `Grid.app/Contents/Resources/grid`, where the resolver's
macOS bundled candidate (`…/Contents/MacOS/../Resources/grid`) picks it up.

> Nuitka can't cross-compile — build each target on its own arch. Linux/Windows
> get analogous scripts (`build_linux.sh`, `build_windows.ps1`) and inject next
> to the executable; resolver candidate `<exeDir>/grid`.

## What bundling does NOT remove

The sidecar removes the "install Python + grid" step. It does **not** bundle the
heavy external runtimes, which `grid` still installs on demand:

- **Docker / Podman** — required by `grid network create`.
- **llama-server** — `grid llama.cpp install` (Homebrew/Metal or CUDA).
- **ComfyUI** — `grid media install`.

The onboarding preflight checks for these and guides the user.
