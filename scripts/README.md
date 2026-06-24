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

## Packaging for distribution

```bash
./scripts/package_dmg_macos.sh            # built .app → drag-to-install .dmg
```

`package_dmg_macos.sh` wraps the bundled `.app` (+ an `Applications` symlink) in a
compressed `.dmg`. It does **not** sign or notarize — the app stays ad-hoc, so
Gatekeeper still warns on download. Fine for internal QA (right-click → Open, or
`xattr -dr com.apple.quarantine Grid.app`).

### Signed + notarized (no Gatekeeper prompt)

```bash
DEV_ID="Developer ID Application: Your Co (TEAMID)" \
NOTARY_PROFILE=grid-notary \
./scripts/notarize_macos.sh
```

`notarize_macos.sh` signs with Developer ID + hardened runtime, builds the dmg,
submits to Apple's notary service, and staples the ticket. **Prerequisites (one
-time, can't be scripted):**

1. A **"Developer ID Application"** certificate in the keychain — created by a
   team Account Holder/Admin at developer.apple.com. "Apple Development" certs do
   **not** work (notarization rejects them).
2. Stored notary credentials:
   `xcrun notarytool store-credentials grid-notary …` (App Store Connect API key,
   or Apple ID + team id + app-specific password).

> The bundled `grid` sidecar is a Nuitka onefile that unpacks + execs at run time;
> under hardened runtime it may need extra entitlements
> (`allow-unsigned-executable-memory` / `allow-jit`) to pass notarization — see
> the comments in `notarize_macos.sh`.

## What bundling does NOT remove

The sidecar removes the "install Python + grid" step. It does **not** bundle the
heavy external runtimes, which `grid` still installs on demand:

- **Docker / Podman** — required by `grid network create`.
- **llama-server** — `grid llama.cpp install` (Homebrew/Metal or CUDA).
- **ComfyUI** — `grid media install`.

The onboarding preflight checks for these and guides the user.
