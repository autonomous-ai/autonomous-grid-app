# Grid

A cross-platform desktop app for the **Grid** peer-to-peer AI network — a Flutter
GUI that drives the [`grid`](https://github.com/autonomous-ai/autonomous-grid)
CLI. Join a grid, run a provider node (llama.cpp / ComfyUI), manage local models,
and chat or generate media against the network — all from one window, on macOS,
Windows, and Linux.

> The app is a **GUI shell around the `grid` CLI**. The CLI owns lifecycle and
> state; the app calls it as a subprocess for control and talks to the network's
> relay over HTTP for the data plane. `~/.grid` is the single source of truth.

---

## Features

| Section | What it does |
| --- | --- |
| **Grids** | Browse, create, and join grids (networks). Manage members and allow/deny lists. |
| **Playground** | OpenAI-compatible chat and media generation streamed straight from the network relay. |
| **Provider** | Run a provider node — configure and stream logs from `llama-server` / ComfyUI backends. |
| **Models** | Manage GGUF models: browse the catalog, pull, and serve them locally. |
| **Debug** | Inspect raw CLI invocations, command logs, and resolved state. |

Provider and Models are shown only on grids where your role can manage a provider;
consumer-only grids see Grids, Playground, and Debug.

First launch runs an **onboarding preflight** that checks for the `grid` CLI,
then guides you through anything missing.

---

## Architecture

Two planes, with the CLI as the backbone:

```
┌──────────────────────── Grid Desktop App (Flutter + Riverpod) ───────────────────────┐
│                                                                                       │
│   Control plane                                    Data plane                          │
│   GridCliService  ──(subprocess)──► grid CLI       RelayClient ──(HTTP/SSE)──► relay   │
│   auth · network · provider · models · media       chat streaming · media events      │
│                                                                                       │
└───────────────────────────────────────┬──────────────────────────┬──────────────────┘
                                         ▼                          ▼
                          ┌──────────────────────┐    ┌──────────────────────────┐
                          │   grid (Python CLI)   │    │  private-server (relay)   │
                          │  spawns / daemonizes  │    │  llama-server / ComfyUI   │
                          └───────────┬───────────┘    └──────────────────────────┘
                                      │ reads / writes
                                      ▼
                 ┌──────────── ~/.grid  (SOURCE OF TRUTH) ────────────┐
                 │ device.toml · credentials.toml · networks/<id>/…    │
                 │ server.log · models/*.gguf · outputs/* · jwks.json  │
                 └────────────────────────────────────────────────────┘
```

**Three invariants:**

1. **Control plane = subprocess.** Every lifecycle command (`auth`, `network`,
   `provider`, `models`, `llama.cpp`, `media`) runs through `grid …`. The app does
   not reimplement process management — the CLI already daemonizes and tracks PIDs.
2. **Data plane = direct HTTP.** Chat and media stream over the relay
   (`{lan_signaling_url}/relay/v1/…`) that `grid consumer env` exposes — no process
   spawned per message.
3. **`~/.grid` is the source of truth.** The app reads state from TOML/logs and
   issues commands; it does not keep a separate cache. Run the CLI from a terminal
   and the app re-renders.

See [docs/Grid_Desktop_App_Plan.md](docs/Grid_Desktop_App_Plan.md) for the full
design rationale.

### Project layout

```
lib/
├── app/                 # MaterialApp, root view, theme wiring
├── core/                # Cross-cutting helpers (grid paths, …)
├── infrastructure/      # OS / CLI integration — the backbone
│   ├── cli/             # GridCliService, GridResolver, command log, parsers
│   ├── state/           # ~/.grid models + the home store
│   └── api/             # Relay data-plane models (chat chunks, media events)
├── features/            # Feature-first modules (logic + presentation)
│   ├── auth/  network/  provider_node/  models/  playground/  onboarding/  debug/
└── shared/              # Reusable widgets, layouts (shell, side nav), theme
```

---

## Tech stack

- **[Flutter](https://flutter.dev)** desktop (Dart SDK `^3.9.2`)
- **[Riverpod](https://riverpod.dev)** (`flutter_riverpod`) for state management
- **[window_manager](https://pub.dev/packages/window_manager)** for the frameless window
- **[toml](https://pub.dev/packages/toml)** to read `~/.grid` config
- **[url_launcher](https://pub.dev/packages/url_launcher)** for device-login flows

---

## Getting started

### Prerequisites

- **Flutter** (stable channel) with desktop support enabled for your platform.
- **The `grid` CLI**, resolved at runtime. The app looks for it in this order:
  **configured path → `GRID_BIN` env → bundled sidecar → `$PATH`**
  (see [`GridResolver`](lib/infrastructure/cli/grid_resolver.dart)). If it can't be
  found, onboarding shows *“Grid CLI not found.”*

For development, install the CLI on your `PATH` or point at a built binary:

```bash
# Option A — install on PATH (resolver finds it last, so a bundled sidecar wins)
cd ../autonomous-grid && uv tool install . --force

# Option B — build the sidecar and point at it (beats a bundled sidecar)
scripts/cli/build_sidecar.sh ../autonomous-grid   # → ../autonomous-grid/dist/grid.dist/
export GRID_BIN="$PWD/../autonomous-grid/dist/grid.dist/grid"
```

> **Option A alone may not be enough.** The bundled sidecar is resolved *before*
> `$PATH`, so a packaged build keeps using the `grid` inside `Grid.app` however new
> the one you just installed is. Use `GRID_BIN`, or re-inject the sidecar with
> [`scripts/bundle_grid_macos.sh`](scripts/bundle_grid_macos.sh).

### Run the app

```bash
flutter pub get
flutter run -d macos      # or: -d windows / -d linux
```

### Test & analyze

```bash
flutter test
flutter analyze
```

---

## Building & packaging

The release flow builds the app, bundles the `grid` CLI as a **Nuitka onefile
sidecar**, signs/notarizes (macOS), and packages an installer. The sidecar binary
is **not committed** (tens of MB, per-platform) — CI builds and injects it.

```bash
# macOS — build app + inject sidecar
./scripts/bundle_grid_macos.sh

# macOS — wrap the built .app in a drag-to-install DMG (ad-hoc, unsigned)
./scripts/package_dmg_macos.sh

# macOS — signed + notarized (no Gatekeeper prompt)
DEV_ID="Developer ID Application: Your Co (TEAMID)" \
NOTARY_PROFILE=grid-notary \
./scripts/notarize_macos.sh
```

> Nuitka cannot cross-compile — each target is built on its own architecture.
> Full bundling/notarization notes are in [scripts/README.md](scripts/README.md).

### Releases (CI)

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds each target and publishes a **draft** GitHub Release with:

```
Grid-<ver>-macOS-Apple-Silicon.dmg   (signed + notarized)
Grid-<ver>-macOS-Intel.dmg           (signed + notarized)
```

macOS only: the Windows job is commented out in the workflow until the app is
code-signed and has an update feed there. `flutter build windows` still works
locally — CI just doesn't publish a zip.

```bash
git tag v0.1.2 && git push origin v0.1.2
```

---

## External runtimes (not bundled)

The sidecar removes the “install Python + grid” step, but `grid` still installs
these heavy provider runtimes on demand:

- **llama-server** — `grid llama.cpp install` (Homebrew/Metal or CUDA).
- **ComfyUI** — `grid media install`.

> **Platform scope:** running a provider (llama.cpp / ComfyUI) targets
> **macOS (Apple Silicon)** and **Linux (NVIDIA)**. On **Windows** the app is
> effectively consumer/playground only.

---

## Documentation

- [docs/Grid_Desktop_App_Plan.md](docs/Grid_Desktop_App_Plan.md) — master architecture plan
- [docs/CLI_Integration_Contract.md](docs/CLI_Integration_Contract.md) — how the app talks to the CLI
- [docs/Project_Structure.md](docs/Project_Structure.md) — module layout
- [scripts/README.md](scripts/README.md) — sidecar bundling, signing, packaging

---

## License

[MIT](LICENSE) © 2026 Huy Pham
