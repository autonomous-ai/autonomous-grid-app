# Grid Desktop App — Architecture, Domain & Features

> Full architecture note, built by reading all of `lib/` (**775 Dart files, ~140,300 lines, 29 feature domains**).
> Updated: **2026-08-12** · branch `main` · version `0.2.0+1`
>
> The 08/10 measurement read **668 files / ~120,900 lines / 26 domains**; the 06/08 one read **558 / ~105,000 / 23**.
> Almost the whole of the latest jump sits in **one new place**: the **Code half**
> (`lib/features/code/`) and the two other new domains it dragged in — `data_sync/` and
> `feedback/`. The panel system that wraps the conversation was also **lifted out of `chat/`
> into `lib/shared/panels/`** so Code could reuse it. See §3 for the **second** navigation axis
> the Code half adds (`ShellMode`), and §7.27–§7.28 for the new domains.
>
> Replaces `docs/OVERVIEW.md` (written 2026-07-14 — before `prompts`, `appearance`, `auto_router`,
> `connectors`, `skills` existed, and before `agents/` grew from a handful of files to 77).
> OVERVIEW.md is still right on build/release and on the CLI-seam description; its feature section is stale.

---

## Table of contents

1. [What this app does](#1-what-this-app-does)
2. [Overall architecture — the planes](#2-overall-architecture--the-planes)
3. [Navigation map — every screen](#3-navigation-map--every-screen)
4. [Infrastructure backbone](#4-infrastructure-backbone)
5. [On-disk data map](#5-on-disk-data-map)
6. [Startup flow](#6-startup-flow)
7. [Domain by domain](#7-domain-by-domain)
8. [End-to-end: one chat turn](#8-end-to-end-one-chat-turn)
9. [Design system](#9-design-system)
10. [Completeness](#10-completeness)
11. [The most important invariants](#11-the-most-important-invariants)
12. [Run, build, release](#12-run-build-release)
13. [Technical debt](#13-technical-debt)

---

## 1. What this app does

**Grid** is a Flutter desktop app (macOS / Windows / Linux) that acts as the **GUI for a peer-to-peer
AI network** of the same name. But that description is only half the story now: as of today, most of the
code by volume is **a tool-using AI assistant that runs right on the user's machine**.

From one window, the app lets you:

| Group | What you can do |
|---|---|
| **AI assistant** | Chat with a locally running agent (Hermes / Codex / Claude Code) — the agent reads/writes files, runs commands, browses the web, drives a real browser, holds a long session |
| **Extending the agent** | Install **skills** (folders of instructions), **plugins** (tool backends), **connectors** (OAuth into Gmail/Slack/Notion/… over MCP) |
| **Automation** | **Scheduled tasks** on a cron; results drop into the Chat tab; a **goal** lets one chat run itself over many turns; **Messages** lets you reach this machine over Telegram/Discord/Slack |
| **Grid (network)** | Create / join a grid, manage members, see how strong the grid is (VRAM, nodes, tok/s), auto-router picking a model |
| **Contributing a machine** | Run a provider node: local `llama.cpp`, an external server (Ollama/LM Studio), or an API engine (OpenAI key / Claude Code seat / Codex CLI seat) |
| **Models** | Browse a catalog suggested for your hardware, download GGUF, serve it, set context length |
| **Playground** | Chat / image generation / video generation over an OpenAI-compatible stream straight from the relay |
| **Projects (Home)** | A project = a folder the assistant may read, plus rules + memory joined onto the opening turn |
| **Working beside the chat** | Two **panels** around the conversation, each with several tabs: **Review** (a project's diff, stage/commit/push, per-line comments), **Terminal** (a real shell over a pty), **Files** (browse & read project files). Their contents flow back into the composer: attach a terminal, attach a file, attach a highlighted snippet |
| **Code (shared repos)** | A second half of the app: shared repositories a grid hosts, read as conversations, where you post a coding task and a teammate's machine runs an agent on it (§7.29) |

### The essence

> **The app is a GUI shell around the `grid` CLI (Python) plus a driver for three external agent
> runtimes.** The CLI owns the grid's lifecycle; `~/.grid` is the source of truth. The app keeps **no**
> state of its own — run the CLI from a terminal and the app redraws itself.

The biggest gap with the old docs: the README and `OVERVIEW.md` describe **two** planes (control =
subprocess `grid`, data = HTTP relay). In reality there are **three** today — the third is the **agent
runtime**, and it is larger than the other two combined.

---

## 2. Overall architecture — the planes

```
┌────────────────────── Grid Desktop App (Flutter + Riverpod) ───────────────────────┐
│                                                                                     │
│  ┌── CONTROL PLANE ───────┐  ┌── DATA PLANE ────────┐  ┌── AGENT PLANE ──────────┐ │
│  │ GridCliService         │  │ RelayApiClient       │  │ ClaudeExecService       │ │
│  │  (3 methods: run/      │  │ ConnectorGateway…    │  │ CodexExecService        │ │
│  │   start/pull)          │  │ ManagedNetworkClient │  │ HermesAcpService        │ │
│  │ subprocess `grid …`    │  │ ModelCatalogClient   │  │ subprocess + stdio      │ │
│  │ auth · network ·       │  │ SmitheryRegistry…    │  │ stream-json / exec      │ │
│  │ provider · models ·    │  │ HTTP + SSE           │  │ --json / ACP JSON-RPC   │ │
│  │ router · projects      │  │                      │  │                         │ │
│  └───────────┬────────────┘  └──────────┬───────────┘  └───────────┬─────────────┘ │
│              │                          │                          │               │
│              │              ┌───────────┴───────────┐              │               │
│              │              │ ConnectorBridge       │◄─────────────┘               │
│              │              │ HttpServer loopback   │  agent calls a tool via      │
│              │              │ /c/<connector>/mcp    │  127.0.0.1:<port>            │
│              │              │ MCP proxy + REST→MCP  │                              │
│              │              └───────────┬───────────┘                              │
└──────────────┼──────────────────────────┼──────────────────────────────────────────┘
               ▼                          ▼                          ▼
   ┌───────────────────┐   ┌──────────────────────┐   ┌──────────────────────────┐
   │  grid (Python)    │   │ the grid's relay     │   │ hermes · codex · claude  │
   │  daemonize, PID   │   │ api-grid.autonomous  │   │ (binaries on the machine)│
   │                   │   │ Smithery, provider   │   │ + Chrome (CDP 9222)      │
   └─────────┬─────────┘   │ MCP servers          │   └───────────┬──────────────┘
             │             └──────────────────────┘               │
             │ reads/writes                                       │ reads config
             ▼                                                    ▼
   ┌──── ~/.grid  (SOURCE OF TRUTH) ──┐        ┌─── ~/.hermes · ~/.codex · ~/.claude ───┐
   │ credentials.toml · state.json    │        │ config.yaml · config.toml · .claude.json│
   │ networks/<id>/ · models/*.gguf   │        │ skills/ · mcp-tokens/ · cron/           │
   │ run/engines/ · outputs/ · logs/  │        │ (the app WRITES here — a projection)    │
   │ app/* (app-owned) · connectors/  │        └─────────────────────────────────────────┘
   │ skills/ · bin/ · tools/          │
   └──────────────────────────────────┘
```

### The three original invariants (still true)

1. **Control plane = subprocess.** Every grid-lifecycle command runs through `grid …`. The app never
   manages a process itself.
2. **Data plane = direct HTTP.** Chat/media stream over the relay (`{lan_signaling_url}/relay/v1/…`).
3. **`~/.grid` is the source of truth.** The app runs a command and then **reads the disk back**; it
   does not parse stdout on success.

### The fourth invariant (from the agent plane)

4. **An agent's config is a *projection*, not a source.** The master store is
   `~/.grid/connectors/tokens.json` and `~/.grid/skills/`. The app projects these into `~/.hermes/`,
   `~/.codex/`, `~/.claude*`. Deleting an entry in an agent's config without deleting it in the master
   store is meaningless — the next projection writes it back.

### The fourth plane — **local tooling** (new, 08/2026)

The panels around the chat spawn a kind of subprocess that is **neither `grid` nor an agent**: `git` and
a **login shell running in a pty**. Both go through their own seam in `infrastructure/cli/`, not through
`GridCliService`:

| | `git` | shell |
|---|---|---|
| Seam | `GitRepoService` (is this folder a repo?) + `GitRunner` (arbitrary argv) | `Pty.start` (`flutter_pty`) |
| Resolve binary | `probeGit()` — **the app's own `~/.grid/tools/git` first, then the machine's** | `resolveShell()` — the user's `$SHELL` |
| Where argv is built | **pure function** `review_argv.dart`, tested | the user types it |
| Who spawns | `infrastructure/` | ⚠️ `features/terminal/logic/terminal_session.dart` — **the feature spawns the process itself** |

> ⚠️ **`GitRunner.run()` takes arbitrary argv.** Unlike `GridCliService` (exactly 3 methods, a closed
> catalog of argv), this is an open door: what keeps it safe is not the type but **discipline** — every
> argv lives in `review_argv.dart` as a tested pure function, and nowhere else assembles argv at the call
> site.
>
> ⚠️ **`git` runs with `GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND='ssh -o BatchMode=yes'`.** The app has
> no terminal, so a `git push` that asks for a password would hang until the timeout with **nobody able
> to type anything**. Turning the prompt off is what lets the screen say "sign in from Terminal" instead
> of spinning. The machine's credential helper **still runs** — only the interactive branch is blocked.

### Code layering

```
lib/
├── main.dart              # boot sequence — the order is a contract
├── app/                   # MaterialApp, RootView (5-way router), single-instance, window lifecycle
├── core/                  # pure helpers: GridPaths, AppEnvironment, host_arch, composer_text
├── infrastructure/        # the backbone — NO business logic
│   ├── cli/               # GridCliService + 3 agent runtimes + Chrome bridge + git seam + parsers
│   ├── api/               # HTTP clients + DTOs
│   ├── mcp/               # ConnectorBridge, McpProxy, RestInvoker
│   ├── state/             # stores that read/write ~/.grid
│   ├── platform/          # clipboard, notification, PDF, font, window focus
│   └── logging/           # 4 disk sinks writing ~/.grid/logs + ErrorBurstFilter
├── features/              # 29 domains, each with logic/ + presentation/
└── shared/                # theme (design system), widgets, layouts (shell/sidebar/settings),
                           # panels/ (the panel system, shared by chat + code),
                           # code/ (syntax highlight), markdown/ (code block + stylesheet), skills/
```

The rule is `presentation → logic → infrastructure`, never the reverse. **There are real violations**
(see §13).

---

## 3. Navigation map — every screen

Navigation now has **two axes**. `ShellMode` (`lib/shared/layouts/shell_state.dart:16`) picks one of the
app's two **halves** — **Home** and **Code** — and `ShellSection` picks a screen inside Home.

### The first axis: `ShellMode` — Home vs Code

`ShellMode` has **2 values**: `home` and `code` (`code` is `devOnly`). The switch lives at the top of the
sidebar. It is a separate axis rather than one more nav row because the same words mean different things
on each side: a *project* in Home is a folder on this computer the assistant may read; a *project* in Code
is a repository the grid hosts, with members and a trunk. `_SectionView` (`home_shell.dart`) reads
`shellModeProvider` first — `ShellMode.code → const CodePane()` replaces the whole pane, so `section == chat`
can be true while the user is looking at a task. `chatIsOpenProvider` (`home ∧ section == chat`) is the one
provider everything that decorates chat asks, so the two axes can't drift.

> Code is **developer-only for now**: the half is built, but the production relay serves no projects
> plane, so a shipped build would offer a whole side of the app whose every screen answers "nothing here".

### The second axis: `ShellSection` — the Home screens

`ShellSection` (`shell_state.dart:120`) has **16 values**. `section_view.dart:37` is the **single mapping
table** `ShellSection → Widget`.

| Section | Widget | Where | devOnly |
|---|---|---|---|
| `chat` | `ChatPane` | The app's default; sidebar "New chat", tray, notification, ⌘K | |
| `scheduled` | `ScheduledView` | Sidebar row | |
| `projects` | `ProjectsView` | Opened from the "Projects" header in the sidebar, ⌘K | |
| `agents` | `AgentsView` | Settings ▸ Customize | |
| `skills` | `SkillsView` | Settings ▸ Customize | |
| `connectors` | `ConnectorsView` | Settings ▸ Customize | |
| `plugins` | `PluginsView` | Settings ▸ Customize | ✅ |
| `git` | `GitView` | Settings ▸ Coding | |
| `engines` | `ProviderView` | **Sidebar row (leads it)** — labelled "Model engines" | |
| `guide` | `HowToUseView` | Settings ▸ Personal ("How to use") | |
| `appearance` | `AppearanceView` | Settings ▸ Personal (**Settings default**) | |
| `dataSync` | `DataSyncView` | Settings ▸ Personal ("Sync & Backup") | |
| `archived` | `ArchivedChatsView` | Settings ▸ Archived | |
| `messages` | `MessagesView` | Settings ▸ Integrations | ✅ |
| `grids` | `NetworksPane` | Settings ▸ Developer | ✅ |
| `debug` | `DebugView` | Settings ▸ Developer | ✅ |

> **`engines` moved out of Settings into the sidebar.** `kSidebarSections = [engines, scheduled]`. Running
> a model is what the product *is*, and it used to be three clicks deep behind the account menu ▸ Settings;
> now "Model engines" leads the sidebar's nav. The screen and the rail label share the words now — it read
> "Model Engines" on the screen and "This computer" in the nav, one concept wearing two names.

**Left sidebar** (folds down to its glyphs via `sidebarCollapsedProvider` / `AppSidebarMini`, ⌘\\): brand +
⌘K · **Model engines** · **Scheduled** · `ChatHistoryList` (Projects → their child chats → a separate
"Chats" run) · account pill. The Home/Code switch sits at the head.

**Settings pane** (replaces the whole shell, no top bar): 6 groups — Personal / Customize / **Coding** /
Integrations / Developer / Archived. A release build draws fewer (an empty group vanishes via
`visibleSettingsGroups`).

> **The only gate is `devOnly × AppEnvironment.isDeveloperMode` (= `!kReleaseMode`)** — i.e. by **build
> mode**, NOT by the user's role or scopes. Role only affects what's *inside* a screen
> (`SharingLockedView`, Delete/Rename buttons owner-only). The README's "Provider and Models only show for
> managing roles" is **no longer true**.

**Screens outside the shell:** `PreflightScreen`, `LoginScreen`, `InstallerScreen`,
`OnboardingChoiceScreen` (4 full-screen screens `RootView` chooses between).

**Unreachable screen:** `OverlordView` and all of `features/overlord/` (**20 files, 1,417 lines**, no
`ShellSection`, no route, 0 references).

### The panel axis — navigation that does NOT go through `ShellSection`

The panel system moved to `lib/shared/panels/` (`panel_tabs.dart`, `panel_metrics.dart`, `panel_slots.dart`,
`panel_surface.dart`, `panel_tab_strip.dart`, `panel_feature_menu.dart`) and is now shared by **chat and
code**. A panel wraps the conversation; each is its own **tab strip**. What opens in it is **not** a
`ShellSection`, has no route, and is not in the `section_view.dart` table:

```
PanelHost.preview   right of a chat conversation   ┐
PanelHost.bottom    under a chat conversation       │ three separate places to work
PanelHost.code      right of a Code project's       │ (each its own tabs)
                    conversation                     ┘

PanelFeature.review    ⌃⇧G   Review   ┐
PanelFeature.terminal  ⌃`    Terminal │ mapping table: chat/presentation/panel_feature_view.dart
PanelFeature.files     ⌘P    Files    ┘   (and code/presentation/widgets/code_panel_feature_view.dart)
```

- **`PanelHost` now has 3 values** — `preview`, `bottom`, `code`. The code panel is rooted at the
  project's checkout on this computer rather than the chat's workspace.
- **`panelTabsProvider` is a `family` over `PanelHost`** — a terminal opened beside the chat must not touch
  the one open under it, or beside a project. Each host is a separate *place to work*, like separate
  windows of one app. `panelOpenProvider`, `panelExpandedProvider`, `panelWidthOverrideProvider` are all
  families over `PanelHost` too.
- **`open()` always makes a new tab; `reveal()` is "show me this".** Shortcuts use `reveal` (press ⌃⇧G
  three times → one Review, not three); the "+" menu and launcher use `open` (picking that row means "add
  another").
- **An open tab stays in the widget tree.** That is what keeps scroll, the folder you had open and a
  half-typed box across a tab switch. Two things escape that and are told via `PanelTabVisible`: an
  **overlay popover** and **work that shouldn't run while nobody is looking**.
- **`shortcut` on `PanelFeature` is a *label*, and now the labels are wired.** `home_shell.dart` binds
  ⌃⇧G → Review, ⌘P → Files, ⌃` → Terminal, resolving which conversation they act beside via
  `_revealBeside` — the chat's, or a Code project's, depending on `shellModeProvider`.
- The menu lists only **what is built**. A browser and a side chat were here while still `TODO — <name>`;
  they were removed — *"a menu that opens onto an empty screen is a worse answer than a shorter menu"*.

**Three panel toggles live in `AppTopBar`** (`height` = 46), in the order the panels surround the chat read
clockwise from the left edge: project rail → bottom → side. The side toggle is **one button for both** the
chat's preview panel and a Code project's code panel (`_SidePanelToggle` switches on `codeProjectIsOpenProvider`)
— *"it must be the same button, not two lookalikes that drift apart"*.

---

## 4. Infrastructure backbone

### 4.1. Control plane — `GridCliService`

The interface is **exactly 3 methods** (`lib/infrastructure/cli/grid_cli_service.dart:76`):

```dart
Future<CliResult>       run(List<String> args, {Duration? timeout});
Future<GridProcess>     start(List<String> args, {Map<String,String>? environment});
Stream<DownloadProgress> pull(List<String> args);
```

**Binary resolution order** (`GridResolver.resolve()`, `grid_resolver.dart`):
1. `configuredPath` (settings — **not wired to UI**) → `GRID_BIN` env
2. Bundled sidecar: macOS `<exe>/../Resources/grid/grid`; Linux/Win `<exe>/grid[.exe]`
   (on Mac Intel it also checks the Mach-O header, **failing open** if it can't parse)
3. System: `~/.local/bin/grid` → `/opt/homebrew/bin/grid` → `/usr/bin/grid` → `$SHELL -lc 'command -v grid'`

Every candidate must exist, have the execute bit, and **not be the app itself** (`Grid` matches `grid` on
macOS's case-insensitive filesystem).

**Decorator stack** (`infrastructure/providers.dart:34`) — the order is a contract:

```dart
RemoteModeGridCliService(          // prepend --remote (except engine/agent/pull commands)
  LoggingGridCliService(           // write CommandLogNotifier → Debug tab
    FileLoggingGridCliService(     // write ~/.grid/logs/app_cli-YYYYMMDD.log
      GridCliServiceImpl(path),    // Process.run/start, runInShell: false
      fileLog),
    recorder))
```

`RemoteMode` is **outermost** so the Debug tab shows the argv that actually ran (`grid --remote sync`),
copyable to a terminal that runs.

**Env for the child process** (a GUI doesn't inherit shell env):
`PYTHONUNBUFFERED=1` (without it the device-login URL never escapes the buffer) · `PYTHONUTF8=1` +
`PYTHONIOENCODING=utf-8` (a Finder launch has no `LANG` → `UnicodeEncodeError`) · `PATH` =
`~/.grid/bin` → `~/.local/bin` → homebrew → system → login-shell PATH → parent PATH ·
`LANG` fallback `en_US.UTF-8`.

#### The full `grid …` argv catalog

**Via `run()`**

| Actual argv | Call site | Parses what |
|---|---|---|
| `grid --remote --version` | `preflight_service.dart:19` (calls `run(['--version'])`; RemoteMode prepends `--remote`) | exit code gates the app; `isSupportedGridVersion` ≥ **0.2.0** (`onboarding/grid_version.dart`) |
| `grid --remote sync` | several sites | only `ok` / `sessionExpired` |
| `grid --remote logout` | `auth_controller.dart` | — |
| `grid --remote use <id>` | create/rename network | — |
| `grid --remote members add <id> <email> --role provider` | `enable_provider_controller.dart` | last line as log |
| `grid --remote leave <grid>` | `provider_run_controller.dart` | — (**deliberately no `--engine`**) |
| `grid --remote leave <grid> --engine <selector>` | `provider_run_controller.dart` | truth re-read from disk |
| `grid --remote catalog` | `models_providers.dart`, `model_catalog.dart` | **two different parsers** over the same output |
| `grid --remote catalog --api <kind> --json` | `api_engine_catalog.dart` | `models[]` + `last_verified` |
| `grid --remote ctx --json <model>` | `models_providers.dart` | `context_length` |
| `grid --remote device-info --json` | `suggested_catalog.dart` | opaque JSON, the app doesn't interpret it |
| `grid --remote rm <file> --yes` | `model_delete_controller.dart` | `--yes` mandatory (stdin isn't interactive) |
| `grid engine status` | `media_status.dart` | `Installed:`/`Running:`/`Bundle X/Y` |
| `grid --remote router enable\|disable\|set-advisors\|status\|models … --json` | `auto_router_controller.dart` | **the only place that parses stdout instead of reading `~/.grid`** |
| `grid --grid <g> project list\|create\|status\|check\|integrate\|promote\|import\|clone\|commit\|member … --json` | Code half (`code_argv.dart`, §7.29) | `--grid` passed on every call, `--json` output |
| `grid --grid <g> task list\|create\|events\|stop … --json` | Code half | task turns |

**Via `start()`**

| Actual argv | Call site |
|---|---|
| `grid --remote login --no-browser` | `auth_controller.dart` — parse URL + `Code:` mid-stream, 5-minute timeout |
| `grid engine install llama.cpp` \| `comfyui` | `engine_setup_controller.dart`, `node_setup_plan.dart` |
| `grid --remote join <grid> --serve <gguf> --endpoint-port <free> [--advertise-as] [--ctx-size] --name <node>` | `provider_run_controller.dart` |
| `grid --remote join <grid> --at <url> -m <model> --ctx-size 200000 --name <node>` | `provider_run_controller.dart` |
| `grid --remote join <grid> --api <kind> [-m …] --name <node>` + env `{KIND_API_KEY}` | `provider_run_controller.dart` — **key never enters argv** |

**Via `pull()`**: `grid pull <spec>` · `grid engine pull <bundle>`

### 4.2. Data plane — HTTP clients

| Client | Base URL | Endpoints |
|---|---|---|
| `RelayApiClient` | `{lanSignalingUrl}/relay/v1` | `GET /models`, `GET /grid/overview` |
| Chat/media (playground) | as above | `POST /chat/completions`, `/responses`, `/media/image/generate`, `/media/image/edit`, `/media/video/i2v` |
| `ManagedNetworkClient` | `api-grid.autonomous.ai` | `POST/GET/DELETE /v1/grid/managed-networks[/{id}/members]`, `PATCH /v1/grid/networks/{id}` |
| `ConnectorGatewayClient` | as above | `GET /v1/grid/connectors`, `POST …/start`, `/poll`, `/refresh`, `/disconnect` |
| `ModelCatalogClient` | as above | `POST /v1/grid/catalog` (suggest + list), `GET /v1/grid/catalog/{repo_id}` |
| `SmitheryRegistryClient` | `api.smithery.ai` | `GET /servers?q=… is:remote` — **sends no credential** |
| `FeedbackClient` | as above | `POST /v1/feedback` (§7.28) |

- `relayBaseUrl` is derived **at the client**: `'$lanSignalingUrl/relay/v1'`, `relayApiKey = accessToken`.
- Auth: the relay uses the **grid's access token**; the control plane uses **session_token** in
  `credentials.toml`.
- Timeouts are **not uniform**: relay `/models` 2/3/4s, `/grid/overview` 3/4/6s, gateway 10+20s,
  managed-network/catalog 10+30s, `RestInvoker` 30s, `McpProxy` 60s.
- **Only the relay + managed-network + skill generator write `CliCallKind.http`.** `ModelCatalogClient`,
  `ConnectorGatewayClient`, `SmitheryRegistryClient`, `McpProxy`, `RestInvoker`, `FeedbackClient` **do not**
  appear in the Debug tab or in `app_https-*.log`.

### 4.3. Agent plane — three runtimes

| | **Hermes** | **Codex** | **Claude Code** |
|---|---|---|---|
| Install | `uv tool install --force --python 3.13 'hermes-agent[acp,mcp]'` | download GitHub release + verify SHA-256 | `curl claude.ai/install.sh \| bash` |
| Command | `hermes acp` (1 arg) | `codex exec [resume] --json --skip-git-repo-check -c …` | `claude -p --output-format stream-json --include-partial-messages --verbose …` |
| Protocol | **ACP JSON-RPC over stdio**, long session | `--json` event stream, 1 process/turn | `stream-json` JSONL, 1 process/turn |
| Model routed by | `~/.hermes/config.yaml` (ACP has no model flag) | several `-c model_providers.grid-app.*` overrides | env `ANTHROPIC_BASE_URL` + `ANTHROPIC_*` |
| API key | config.yaml + `.env` | env `GRID_APP_API_KEY` | env `ANTHROPIC_AUTH_TOKEN`/`API_KEY` |
| Approval | ✅ **has a real ACP channel** | ❌ `sandbox_mode="danger-full-access"` | ❌ `--permission-mode bypassPermissions` |
| Message event | **delta** (accumulated) | **whole text** (replaces) | **whole text** (replaces) |
| MCP | `mcp_servers:` in config.yaml | `~/.codex/config.toml` | `--mcp-config <file> --strict-mcp-config` |
| Resume | session lives in the process | `exec resume <threadId>` | `--resume <sessionId>` |
| Unique | cron, gateway messaging, plugins | — | browser lane (extension / CDP) |

> ⚠️ **There is no type called `AgentEvent`.** `infrastructure/cli/agent_event.dart` is only a **shared
> vocabulary** (`AgentActivity`, `AgentPlanEntry`, `AgentPermission`, `AgentApprovalMode`,
> `AgentDetailMode`, `WebSource`). The three runtimes keep **three fully separate sealed families**:
> `HermesAcpEvent` (7 branches, `hermes_acp_service.dart`), `CodexExecEvent` (7 branches,
> `codex_exec_service.dart`), `ClaudeExecEvent` (**10 branches**, `claude_exec_event.dart`). They meet only
> at **`ChatSendUpdate`**.
>
> Practical consequence: adding one new concept to every agent (say "the agent asks for confirmation") =
> editing 3 sealed families + 3 senders + 3 parsers, with **no compile error** to remind you if you forget
> one. Three semantic differences already exist that **no type records**: message is delta vs whole text;
> only Hermes has permission; only Hermes has a long-lived session.

**The real convergence point** is `ChatSendUpdate` (sealed, **5 branches** —
`ChatSendGenerating`, `ChatSendStreaming`, `ChatSendAgentSession`, `ChatSendSuccess`, `ChatSendFailure`;
`playground/logic/chat_sender.dart:23`) — **all four sending paths** (relay + 3 agents) drain into it.
`ChatSender` is a **1-method, 11-parameter** interface, but **at least one impl deliberately ignores 5 of
the 11** (`workdir`/`instructions`/`planFirst`/`approval`/`conversationId` with relay; `approval` with
Codex and Claude) — the interface is **wider than the real contract**.

**Session bookkeeping:** `AgentSessionSlots` keyed by `networkId|model|conversationId|workdir`, LRU 5.
Hermes **doesn't** use it (a slot holds a live process, and eviction must `close()`) — `HermesChatSender`
has its own LRU.

**`slot.seen++` only on a successful turn** — a failed turn appends nothing, and a miscount makes the next
turn re-quote the agent's own words as "context you missed".

### 4.4. MCP bridge — connector → agent

`ConnectorBridge` is **a single loopback `HttpServer`** (`infrastructure/mcp/connector_bridge.dart`), the
port remembered in `~/.grid/connectors/bridge.json`, serving
`POST http://127.0.0.1:<port>/c/<connector>/mcp`.

```
agent calls a tool ──► bridge ──┬─ effectiveTransport == mcp ──► McpProxy.forward
                                │     POST <provider url>, attach credential headers
                                │     Accept: application/json, text/event-stream  ← BOTH required
                                │     unwrap the LAST `data:` of the SSE
                                │
                                └─ transport == rest ──► RestInvoker
                                      build the HTTP from a RestTool template + the model's arguments
                                      check `required` here, don't trust the model
```

- The bridge reads the token **every call, never caches**; renews it if expired (deduped via `_refreshing`).
- Credentials **stay in the app** — the agent's config holds only a loopback URL, no headers.
- ⚠️ **The bridge authenticates nothing.** Any local process can POST and spend credentials. The only
  fence is the loopback-only bind.

### 4.5. Logging — 4 disk sinks

All use `DailyLogFile`: **synchronous write + flush** (survives a force-quit), one file per day, prune > 14
days.

| File | Contents |
|---|---|
| `~/.grid/logs/app-YYYYMMDD.log` | `[ts] LEVEL category message` + stack trace; `FlutterError.onError` routes here from the first line of `main()` |
| `~/.grid/logs/app_cli-YYYYMMDD.log` | `[HH:MM:SS] #N $ grid …` / `#N \| out` / `#N ! err` / `#N ← done exit=0 (4s)` |
| `~/.grid/logs/app_https-YYYYMMDD.log` | `#N → POST https://…` / `#N ← ok status=200` |
| `~/.grid/logs/app_node_setup-YYYYMMDD.log` | numbered plan + `-- Step i/n --` |

**Log security — two invariants:** only the **names** of env vars enter the log (`envKeys`); the
`Authorization` header is **never** written (only an `authorized` flag). Adding `--api-key` to argv leaks
the key into both the Debug tab and the transcript.

#### `ErrorBurstFilter` — why the log needs a valve

`DailyLogFile` writes **synchronously + fsyncs on the UI isolate**. An exception thrown from
`build`/`paint`/a frame callback **doesn't happen once — it repeats every frame**. On 06/08 a tooltip
assertion in the mouse tracker repeated **11,406 times in two and a half minutes**, wrote **19MB** of
identical stack traces, and the app had to be killed.

`main.dart`'s error handlers now filter through `ErrorBurstFilter` (`window` 30s, matched on the **first
line** truncated to 200 chars, max 256 signatures then cleared). The first copy carries the diagnosis; the
rest only need to be **counted** — the log writes `[+3000 identical since the last copy]`.

> `platformDispatcher.onError` keys on **the error itself**, not on the `'Uncaught error'` sentence in
> front of it — every uncaught error shares that sentence, and one repeated error must not silence the next.

### 4.6. Local tooling — `git` + pty

See §2 for where this plane sits. Details:

**`probeGit()` — the order and a trap only macOS has**

1. `~/.grid/tools/git` (the app's own download) → 2. the machine's Git.

> ⚠️ **On macOS you must never exec `/usr/bin/git`.** That file **exists on every Mac** — it's one of 78
> hard links to the same `xcode-select` stub, so an "exists" check proves **nothing**. Running it without
> the Command Line Tools installed **pops Apple's install dialog** over whatever the user is doing — a
> *probe* turned into an *invitation to install*. The Mac branch therefore resolves the developer directory
> with `xcode-select -p` (a different binary, never prompts), then runs git inside it by absolute path.

`GitStatus` is sealed with **4 branches**: `GitReady{path, version, ours}` · `GitMissing` · `GitTooOld` ·
`GitCannotCarryCredential` — `GitTooOld` is split from `GitMissing` so the copy can say *upgrade* instead of
*install*.

**Installing Git — one path only.** `BackgroundGitInstaller` (launch, silent) and the button in
Settings ▸ Git **both go through `GitInstallController`**: it holds a single-flight guard, re-probes and
adopts. Two separate callers would race into the same target directory and leave a half-built tree.

> **The user's own Git always wins.** The app only fills a gap. Git carries **the user's** credential
> helper, proxy and certificate — replacing it breaks cloning private repos in a way that *looks like our
> bug but is theirs*.

`gitStatusProvider` is a `FutureProvider` **cached for the life of the app** (the probe spawns a process).
Anything that installs or removes Git **must invalidate it** — just as `agentInstalledProvider` does with
`reprobeAgent`.

**pty** (`flutter_pty` + `xterm`): `resolveShell()` takes the user's `$SHELL`. Three things have been real
bugs:

- `TERM=xterm-256color` + `TERM_PROGRAM=Grid` **must spread over `Platform.environment`** — an app launched
  from an IDE inherits `TERM=dumb`, and `dumb` turns off colour, cursor and every full-screen program
- **`xterm` counts columns-then-rows, the pty counts rows-then-columns** — passing them straight through
  transposes the two numbers on every resize
  (`terminal.onResize = (w, h, _, _) => pty.resize(h, w)`)
- **Kill with `SIGHUP`, not `SIGTERM`** — that's what closing a terminal window sends, so the shell hangs
  up its child (a running `flutter run`) instead of leaving it holding a pty nobody reads.
  Windows only knows `SIGTERM`/`SIGKILL` — asking for anything else throws

---

## 5. On-disk data map

### `~/.grid` — the CLI owns it

| Path | Who writes | Format | Module that reads |
|---|---|---|---|
| `credentials.toml` | CLI | TOML | `sessionProvider` ← `GridHomeStore.readCredentials()` |
| `state.json` | CLI (`grid use`) | JSON | `activeRemoteGridProvider` (`active.remote`) |
| `api_keys.toml` | CLI | TOML | `storedApiKinds()` — reads **presence only** |
| `networks/<id>/config.toml` | CLI | TOML | `readNetworkConfig(id)` |
| `models/*.gguf`, `*.part` | CLI (`grid pull`) | binary | `localModelsProvider`, `downloadingModelsProvider` |
| `outputs/*` | app + CLI | media | `saveMediaOutputs` |
| `run/engines/<gridId>/<engineId>.json` + `.log` | CLI | JSON | `listEngineRuns()` — **scans the folder, doesn't guess names** |
| `logs/*` | app | text | Debug tab "Open logs" |
| `bin/` | app + CLI | binary | `uv`, `llama-server`, `codex`, agents |
| `tools/`, `python/` | `uv` | — | Hermes venv |
| `tools/git/` | app (`GitInstaller`) | binary tree | `probeGit()` — **extracts the whole tree**, not just the `git` file: without `libexec/git-core` an HTTPS `git clone` dies with `'remote-https' is not a git command`. Reached via `HostEnvironment.gitEnvironment()` |

### `~/.grid/app` — the app owns it (the CLI never touches it)

| File | Contents |
|---|---|
| `chats/<id>.json` | A conversation's whole transcript (`GridPaths.chatsDir`) |
| `chat_prefs.json` | grid, model, approval, detail mode, themeMode, chatAgent, 2 font families + 2 sizes — **the app's defaults**, applied only to chats outside any project |
| `projects.json` | `Project{id, name, path, instructions, memory, pinned, agent?, model?}` — `agent`/`model` null = follow the app default |
| `project_tasks.json` | `{jobId → projectId}` |
| `prompts.json` | The `/` prompt library |
| `onboarding.json` | `{"decision": "local"\|"openai"\|"later"}` |
| `model_context.json` | Context windows **learned from engine errors** (the relay doesn't advertise them) |
| `task_delivery.json`, `task_inbox.json`, `task_unread.json`, `task_serving.json` | Bookkeeping for the cron-result sweep |
| `agent-workspace/` | The agent's default workdir when a chat belongs to no project |
| `code/<project>/` | **The app's working checkout of a shared Code project** — one folder each (`GridPaths.codeDir` / `projectCodeDir`). Kept here rather than asking the user for a path; the flow refreshes it after a task ships, the header button opens it, and the code side panel browses/reviews/runs a terminal in it (§7.29) |
| `sync_state.json`, `backups/<stamp>.zip` | Sync & Backup marker + encrypted bundles (§7.27) |
| `services/<name>.json` + `.log` | Records left by the `grid-serve` skill |
| `chrome/` | The bridge's own Chrome profile (**not logged into anything**) |
| `claude-mcp-config.json` | The MCP config written **each turn** for Claude |

### `~/.grid/connectors` — the connector master store

| File | Contents | Mode |
|---|---|---|
| `tokens.json` | **Source of truth** for OAuth tokens | 600 |
| `clients.json` | Registered DCR clients, keyed by **issuer** | 600 |
| `manual.json` | MCP servers the user typed by hand | 600 |
| `bridge.json` | The bridge's remembered port | — |
| `projections/codex.json` | Sidecar marker (Codex swallows unknown keys) | — |

### `~/.grid/skills` — the skill library

`user/<slug>/` (user-written) · `public/<slug>/` (from the catalog + Grid built-ins).
**Which folder it lives in *is* its authorship** — no manifest has to be kept in sync.

### The agents' folders — the app WRITES into them (projection)

| Path | What the app writes |
|---|---|
| `~/.hermes/config.yaml` | `model.default`, `custom_providers`, `mcp_servers`, `platform_toolsets.cron`, `approvals.*` — via `YamlEditor`, always `.bak` first |
| `~/.hermes/.env` | Telegram/Discord/Slack tokens + allowlist — via `EnvFile`, always `.bak` |
| `~/.hermes/mcp-tokens/<name>.json` | OAuth credentials (RFC 6749 §5.1), chmod 600 |
| `~/.hermes/skills/<slug>/` | Copied skill |
| `~/.hermes/cron/jobs.json`, `output/<jobId>/*.md`, `ticker_heartbeat` | Hermes writes, the app **reads** |
| `~/.hermes/gateway_state.json` | Hermes writes, the app reads `platforms.<key>.state` |
| `~/.codex/config.toml` | `mcp_servers` — **re-encodes the whole file** (loses comments/key order), `.bak` is the only safety net |
| `~/.codex/.env` | `GRID_API_KEY` |
| `~/.codex/skills/<slug>/` | Copied skill |
| `~/.claude.json` | `mcpServers` (marker `_grid`) — 72 KB of the user's state, merged carefully |
| `~/.claude/settings.json` | Only the `env` block (from the "How to use" screen) |
| `~/.claude/skills/<slug>/` | Copied skill |

---

## 6. Startup flow

### `main.dart` — the order **is a contract**

1. `WidgetsFlutterBinding.ensureInitialized()`
2. **Logging first** — `FileAppLog` + `FlutterError.onError` + `platformDispatcher.onError`
   → a crash at startup still leaves a stack trace on disk
3. `MediaKit.ensureInitialized()` (libmpv for inline video/audio)
4. **Single-instance** — `ServerSocket.bind(127.0.0.1:52677)` + a liveness probe byte `0x47`
   (`app/single_instance.dart`). Bind fails and nobody answers → **carry on anyway** (better two instances
   than the app closing itself over a stuck port)
5. `windowManager` + `setPreventClose(true)` (arms `onWindowClose`), 1280×800, min 880×560,
   titlebar hidden on macOS
6. **Sparkle** — set the feed URL (`{arch}` replaced by `arm64`/`x86_64`), interval 86400s.
   **Deliberately no immediate check** — the launch check is in `HomeShell`
7. **Build** `SystemDesktopNotifier` — but **do NOT ask for permission here** (see the warning below)
8. `runApp(ProviderScope(overrides, child: ConnectorRefreshScope › GridSkillsScope › NotificationScope › GridApp))`

> ⚠️ **Step 7 changed, and the reason was a real bug.** `ensurePermission()` **doesn't return until the
> user answers the OS dialog**. The window is built in step 5 but no frame is painted until `runApp` — so an
> `await` here left a **black, un-closeable window** the whole time the dialog stood there (on the first
> launch after each update). The notifier is now overridden **unconditionally** (`show` no-ops until it
> knows the answer), and asking is deferred to `HomeShell`, after the first frame.

The two outermost scopes sit **outside the router** because connector tokens and skills belong to *the
agent* — the agent answers chats whether or not the user has the Connectors/Skills screen open.

### `RootView` — the 5-way router

```
preflightProvider.when(
  loading → _Splash("Starting Grid…")
  error   → _ErrorView + Try again
  data(r) → 1. !r.canProceed                          → PreflightScreen
            2. !isLoggedIn || expiry == needsLogin    → LoginScreen
            3. showInstallerProvider                  → InstallerScreen
            4. switch (onboardingRouteProvider):
                 resolving → _Splash
                 choose    → OnboardingChoiceScreen
                 home      → HomeShell
)
```

- `canProceed == gridAvailable` — `grid --remote --version` exit 0 and version ≥ 0.2.0.
  A version that **won't parse PASSES** (blocking a checkout-from-source is worse).
- `isLoggedIn` alone isn't enough: a dead token still sits in `credentials.toml` → it has to add
  `needsLogin`.
- The installer gate is now **just `!hermesInstalled`** — engine and model are no longer conditions.
- `routeFor` takes a `GridOverview?`, **not** an `AsyncValue` — taking `AsyncValue` would make every
  background-poll `loading` frame → splash → remount top bar → re-poll: 3 round-trips/second.

### `HomeShell` mount — 7 post-frame jobs

1. `BackgroundModelController.startIfNeeded()` — background model download (guarded by a chain of conditions)
2. `BackgroundAgentInstaller.startIfNeeded()` — install missing agents, silently
3. `BackgroundGitInstaller.startIfNeeded()` — adopt the user's Git, or fetch the app's, silently
4. `TaskDeliveryController.start()` — `Timer.periodic(30s)` sweeping cron results into chat
5. `_markTaskChatRead(activeId)`
6. `appUpdater.checkInBackground()` — placed here so the Sparkle prompt doesn't land on top of a model
   download
7. `desktopNotifier.ensurePermission()` — **the same two reasons**: it must not fall in the middle of
   first-run setup, and asking in `main` holds back the first frame (a black window). Here the app is
   drawn and the ask makes sense — the user is looking at exactly the thing that's asking

**Shell shortcuts:** `⌘K` palette · `⌘,` Settings · **`⌃⇧G` Review** (Codex's binding for the same thing) ·
**`⌘P` Files** · **`⌃`` Terminal** · **`⌘\\` fold sidebar**. `_revealBeside` sends Review/Files (and, in
Home, `_reveal(PanelHost.bottom, terminal)`) to the panel beside whichever conversation the user is looking
at — the chat's, or a Code project's — switching to Chat first when firing from Settings, since the panel
lives in the Chat tab.

### Teardown — must have **both** paths

- The window close button + tray "Quit" → `onWindowClose()` (thanks to `setPreventClose(true)`)
- **⌘Q / app-menu Quit / OS log-out** → `didRequestAppExit()` — `setPreventClose` **does not** cover this
  path

Both call `shutdownServing()` (8s timeout, `app/window_lifecycle_scope.dart`): kill child processes, then
`grid leave` for every grid in `{_grid} ∪ listServingGrids()`. Missing either path orphans a `llama-server`.

A hard kill can't be caught — that engine is **re-adopted** on the next run via `reconcile()`.

---

## 7. Domain by domain

### 7.1. `chat/` — the main conversation surface

**Owns:** the lifecycle of a *saved conversation* — the `Conversation` model, persistence at
`~/.grid/app/chats/<id>.json`, send/stream/cancel state **per chat** (several chats can be answering at
once), and all the UI around it.

`ChatSessionsController` (`chat_sessions_controller.dart`, **~644 lines** — split by the four jobs it does
into part files `chat_sessions_send`, `chat_sessions_state`, `chat_sessions_goals`, `chat_sessions_settle`)
is the core. State:

```dart
conversations: List<Conversation>   // all of them, including archived
activeId, draftProjectId, loading
runningAgentIds: Set<String>        // chats mid agent-turn (1 lane / project)
phases: Map<String, SendPhase>      // only busy chats
errors, awaitingPlanIds, queued: Map<String, List<QueuedTurn>>
```

Getters come in pairs — a "for the open chat" version (`phase`, `sending`) and a "for any chat" version
(`phaseFor`, `sendingFor`, `agentRunningIn`) because the sidebar has to mark a background chat that's
running.

> **Several agent turns running at once ⇒ every live turn state must be keyed by conversation.**
> `agentRunsProvider` (steps + sources + plan, read via `agentRunProvider(chatId)`),
> `agentPermissionsProvider` (read via `agentPermissionProvider(chatId)`) and
> `AgentChangesController.record(chatId:)` all take a chat id. They used to be **one** shared slot — which
> is exactly why the whole app had to serialize: a second turn overwrote the first's `_respond` and hung
> that chat until timeout.

#### `send()` — 11 steps (`chat_sessions_send.dart:16`)

1. Trim, drop empty
2. **Busy → queue** → `_enqueue(QueuedTurn)`. The composer is **not** disabled — that's why the queue exists
3. Pick the target chat (`_activeOrNew` makes an id = microsecondsSinceEpoch)
4. Read approval **once** — the turn runs in the mode it was in when Send was pressed
5. Decide the planning turn
6. `buildUserTurn` — images written to `~/.grid/outputs`, file text already extracted at attach time
7. First-time naming (`deriveConversationTitle`) — once only
8. **`_commit()` writes disk BEFORE sending** → the user's message can never be lost
9. `agentAnswersTurn(modality, hasAttachments, agentInstalled)` — an agent takes **text only, no
   attachments, and must be installed**
10. **Serialize the agent turn per PROJECT**: one lane per project (`runningAgentIds` +
    `_agentQueues[projectId]`). Two chats in the same folder queue (they edit the same files); different
    projects — or **outside every project** — run in parallel. Relay/media turns touch no lane
11. `return done.future` — `await send(...)` waits for the turn to settle (the goal loop relies on it)

#### Sub-features

| Feature | Mechanism |
|---|---|
| **Archive** | `archivedAt` is a **timestamp, not a bool**. `copyWith` needs a `clearArchivedAt` flag. `_commit` auto-unarchives when the user talks in the chat |
| **Pin** | `liveConversations()` pushes pinned to the front |
| **Goal** | `ChatGoal{objective, maxTurns=10, maxMinutes=30}`, pure state machine `advanceGoal`. A reply matching `^GOAL COMPLETE$` → done. `resumeGoal` grants a **brand-new budget** |
| **Plan mode** | approval = `plan` → a read-only turn + `withPlanPreamble` → `PlanApproveBar` → "Approve & run" sends the approving line with `planFirst: false` |
| **Queue follow-up** | Typing more while the agent runs → a queue with an X button; drained one at a time after the prior turn settles |
| **Attachment** | 3 entry points (+ button, ⌘V, drag-drop). Images cap 4, files cap 5, 25 MB. Text extraction: PDF via native (macOS only), docx/xlsx/pptx OOXML-parsed, truncated at 20,000 chars |
| **@-mention** | `activeMention(text, cursor)` — `@` must open a token; the menu reads `workdirEntriesProvider` (one level, cut at 60 rows) |
| **`/`-prompt** | The prompt library; **mutually exclusive with `@`**, prompts win |
| **Minimap** | A tick rail on the left, marking **user turns only**, shown only when content ≥ 1.5× the viewport |
| **Chat from a scheduled task** | id = `task-<jobId>`; `deliverFromAgent` creates the chat if absent and **doesn't** change `activeId` |

#### The panels around the conversation — geometry lives in `shared/panels`, contents elsewhere

`chat/` **owns the panel's place and size** for the chat host; the shared panel system provides the tab
strip, launcher and surfaces. `chat/` knows nothing about what Review/Terminal/Files are (except one file:
`panel_feature_view.dart`, the mapping table).

| File | Owns |
|---|---|
| `shared/panels/panel_tabs.dart` | `PanelHost` (3), `PanelFeature` (3), `PanelTab`, `panelOpenProvider`/`panelTabsProvider` families |
| `shared/panels/panel_metrics.dart` | **All the geometry constants** + `resolveSidePanel()` and the tab-strip width functions, all pure; `panelExpandedProvider` / `panelWidthOverrideProvider` |
| `chat/logic/preview_panel.dart` | `previewPanelOpenProvider`/`previewPanelExpandedProvider` (aliases of the shared providers at `PanelHost.preview`) |
| `chat/logic/bottom_panel.dart` | `bottomPanelOpenProvider` (`PanelHost.bottom`) |
| `chat/logic/composer_context.dart` | which terminal will ride the next message |
| `shared/panels/panel_slots.dart`, `panel_surface.dart`, `panel_tab_strip.dart`, `panel_feature_menu.dart` | the dock/float/main slots, the surface (toolbar + tabs + launcher), the tab strip, the "+" menu |

**`resolveSidePanel()` is a pure function, out of `build`** — its clamps have to agree with each other, and
since dragging exists two of them have a second source. A drag is only a **request**: a request that would
overflow the composer beside it, or wipe out the transcript, is met with the nearest size that **doesn't**.

**`kSidePanelMinWidth = 420`, `kSidePanelMaxWidth = 760`** — the max caps only the **share the app picks by
itself**. Once the user has grabbed the seam they've said what they mean, and the only thing left to protect
is the floor of whatever is beside it.

**`kProjectMinWidth = 440` (chat's `kChatMinWidth` counterpart) is a MEASURED number, not a reasoned one —
and the first measurement was wrong two ways**, shipping stripes across the real composer: the harness built
a bare `ComposerSection` while the chat view wraps it in `Padding(20,10,20,20)` (40px short), and swapped the
three pickers for one pill that shrinks further than the real `ComposerTrigger` (real floor ≈ 58px whatever
the label says). Re-measured: clean at 396, overflowing at 392.
**Re-measure before changing — the failure mode is stripes, not "looks a bit tight".**

**A dragged override resets to `null` at rest, not to a number.** A stored default would **stop answering to
the window's width**, so a panel sized on a big monitor arrives fixed and wrong on a laptop. Once dragged it
sticks for the session — long enough to be a decision, not so long that a bad drag outlives it.

**The default cap ≠ the drag cap.** `kSidePanelMaxWidth = 760` and the tab-strip constants only bound what
the app chooses on its own. Once the user has taken hold of the seam they've spoken, and the only thing left
to protect is the other side's floor.

**`_clamp` is hand-written, not `num.clamp`** — `clamp` asserts `low <= high`, so a pane narrower than both
floors would **throw instead of degrading**. Here "out of room → the room wins".

Three small things, each a fixed bug:

- **`PanelSplitter` uses `dragStartBehavior: DragStartBehavior.down`** — the default (`start`) discards the
  slop-crossing motion, so the seam lagged the pointer by a few pixels and **stayed there for the whole
  drag**
- **The mouse-catch strip (7px) is wider than the line (1px)** it draws — which is why it can't just be a
  `Divider` wrapped in a `MouseRegion`
- **The tab strip shrinks tabs with the count, then scrolls** (`kTabMaxWidth` 180 → `kTabMinWidth` 96) — a
  narrow panel used to push the "+" out of sight at the fourth tab, and **a control you have to scroll to
  reach is one people conclude is missing**

**`panelExpandedProvider` `watch`es `panelOpenProvider` in `build()`** so opening/closing the panel resets
expanded. Without it, closing while expanded leaves the flag set, and the next open **swallows the whole
conversation with no warning**.

**Panels are deliberately NOT persisted and NOT per-chat.** A panel answers *"am I working in here right
now"*, unlike the project rail (*"do I want this project's card"* — that one sticks).

#### Panel contents flow back into the composer

| Path | Mechanism | Cap |
|---|---|---|
| Attach a terminal | `attachedTerminalsProvider` **derived** from which panel is open + whether its active tab is a terminal | max 2 (one per panel), **counted nowhere** |
| Attach a file | `composerFileRequestProvider` ← Files: right-click "Add to chat"; Review: the ✚ button next to the open file's name | `kFileTextBudget` (20,000) |
| Attach a highlighted snippet | `composerSnippetProvider` (**a queue**, not a single value) ← the Files viewer **and** the Review diff | `kSnippetBudget` 4,000 chars × `maxChatSnippets` 8 |
| Ask the agent to review | `composerPrefillProvider` ← Review's "Ask the assistant" | — |

> **A terminal is captured at Send, not earlier.** The minute between opening a terminal and asking about it
> is often **exactly** the minute being asked about: a build still running when the chip appeared has
> already failed by the time the message goes. Capturing at Send is what makes the attachment worth having.

- The terminal chip is **derived**, so it needs a `dismissedTerminalsProvider` — with nothing remembering
  the ✕, the next frame rebuilds the chip. Dismissal belongs to the **draft**, so `clear()` runs at Send
- A terminal takes its **tail** (200 lines / 8,000 chars), **never its head** — what makes someone attach a
  terminal is what just happened in it. Character truncation cuts from the front too, same reason
- An empty terminal returns `null`, **not** an empty block — a message that says "attached" while attaching
  nothing is a lie
- `ChatContext` sits **beside** the text, not **inside** it (like an attached file): the bubble shows a
  chip, the model reads `promptBlock`. Burying the user's line under 200 lines of build output is the
  version that made transcripts unreadable
- Snippets are the **opposite — folded straight into the text** (`messageWithSnippets`), because that's what
  makes the transcript honest: the user's turn shows exactly what they asked, quote included
- **One selection, one menu.** `AddToChatSelection` (shared) builds the same three rows — Add to Chat, a
  rule, Copy, Select all — for *both* drag-select and right-click; the platform's default strip is off
  (`contextMenuBuilder: null`) and its two actions are done in place. Before, the two gestures produced two
  differently-shaped menus, to be learned twice
- The Review diff wraps it in `LineSelection`: the list draws **one widget per line**, so the default
  selection glues everything into one long line. Line numbers (`lib/x.dart:11-12`) come from
  `diffExcerptFor` re-probing, and are given **only** when the highlight is one contiguous run of the file
  *after* the change — a deleted line is in no file to point at

#### The most expensive traps

- `archivedAt` **must** be parsed with `_parseNullableDate` — `_parseDate`'s epoch fallback makes every old
  chat "archived 1970" and empties the sidebar after an update
- `_restore` has to open the first **live** chat, not `conversations.first`
- Everything that reads chat history uses `state.live`, **not** `.conversations` — 4 sites had to be fixed
- `_syncModelField` must **wait for `options` to be non-empty** before marking synced
- `ChatStore.save` is a **synchronous write on the UI thread**, rewriting the whole file every turn
- ⚠️ `chat_header.dart` `_menuSize` computes **4 rows + 1 divider** but `_ChatMenuContent` builds
  **6 rows + divider + Delete = 7** → off by ~108px. **Still wrong.**

### 7.2. `agents/` — the agent abstraction layer (77 files, the largest)

**The single seam** between the `chat`/`skills`/`plugins`/`connectors` features and the three concrete
runtimes: nothing outside `agents/logic/adapters/` knows the class names `Hermes*`/`Codex*`/`Claude*`.

#### Adapter matrix

| Axis | Hermes | Codex | Claude Code |
|---|---|---|---|
| Probe binary | `hermes_tool.dart` | `codex_tool.dart` | `claude_tool.dart` |
| Chat sender | `hermes_chat_sender.dart` | `codex_chat_sender.dart` | `claude_chat_sender.dart` |
| Extensions | `hermes_extensions.dart` | `codex_extensions.dart` | `claude_extensions.dart` |
| MCP config | YAML | TOML | JSON |
| Connector projection | + `hermes_token_projection` | sidecar marker | in-entry marker |
| Unique | `hermes_grid_link`, `hermes_skill_scanner`, `hermes_shared_skills` | — | `claude_browser`, `claude_turn_mcp_config` |

#### Who answers a turn

```
ChatSessionsController.send()
  → chatAgentForProjectProvider(conversation.projectId)   ← fixed AT send, like approval
      chatAgentChoiceProvider = project.agent ?? chatPrefs.chatAgent
      resolve (NOT saved): pick it if _canAnswer (installed && agentRunsOnGrid)
                           else borrow the first agent that clears both bars
                           finally kChatAgent = hermes
  → agentAnswersTurn(modality, hasAttachments, agentInstalled)
      false → chatSenderProvider (relay HTTP)
      true  → agentChatSenderProvider(agent)
```

The user's pick is **never overwritten** → switching grids and back restores it.

#### Agent + model follow the project

`chat_scope.dart` is the *only* place that decides where a choice is written:

```
openChatProjectIdProvider  = chatSessions.openProjectId (a saved chat, or the draft)
chatScopePrefsProvider.setAgent/setModel
    in a project → ProjectsController.setAgent/setModel   (projects.json)
    outside one  → ChatPrefsController.setChatAgent/setModel (chat_prefs.json)
read back: chatAgentChoiceProvider(projectId) / chatScopeModelProvider
```

The three places a user changes agent (the composer `AgentPicker`, the card in Agents, `SwitchAgentButton`)
all go through here, so no place writes the wrong scope. The agent is fixed **per conversation**, not per
open chat: a follow-up queued in project A must be answered by A's agent even if the user has moved to
project B. `ProjectAssistantCard` in the rail only *shows* it + a "back to app default" button — the real
pick is in the composer.

#### Approval flow — **only Hermes has a channel**

```
ACP permission request
  → decideHermesPermission(toolKind, options, mode)
      toolKind ∈ {read, search, fetch, think}  → allow at once, no prompt
      readOnly / plan                          → HermesRefuse
      ask                                      → HermesAskUser
      full                                     → allow_once (NEVER allow_always)
  → AgentPermissionController.ask(), 55s timeout (Hermes gives up at 60s)
  → AgentPermissionCard pinned ABOVE the composer (not in the transcript, not scrolled away)
```

> ⚠️ **Codex and Claude Code run `danger-full-access` / `bypassPermissions`** — they write files and run
> commands **anywhere on the machine, asking no one**. `claude -p` / `codex exec` are non-interactive and
> **have no approval channel**. The `ApprovalPicker` in the composer shows for every agent but **governs
> only Hermes**. This is a `TODO(BE)` spelled out at `codex_chat_sender.dart:55` and
> `claude_chat_sender.dart:69`.

#### Five built-in `grid_*` skills

| Skill | Script | Does what |
|---|---|---|
| `grid-web` | `search.py`, `read.py`, `browse.py` | Search & read the web via `uv run --with ddgs/trafilatura/playwright`. **Codex and Claude Code on a grid have no web search** — their tools come from the vendor API |
| `grid-host` | — | "What's on this machine" — macOS has no `timeout`/`gh`/`rg`. Distilled from 83 recorded Codex turns |
| `grid-serve` | `serve.py` (~540 lines) | Run a service that outlives a tool call: launchd → screen → tmux → detached |
| `grid-research` | (uses `grid-web`'s scripts) | A research method: many queries, read real pages, a "Not verified" section |
| `grid-chart` | — | Teaches the agent the ```` ```chart ```` format the transcript renders. Without it the chart feature is **invisible** |

Installed at launch via `GridSkillsScope`, written to **two** places (the library + the agent's folder),
**rebuilt rather than copied** (the card embeds an absolute path to its own script). **Written only when the
folder doesn't exist** → a card whose copy changed in a new build **does NOT** reach an agent that already
has that skill.

#### Claude MCP handshake — the main quirk

`claude -p` loads **every** server in `~/.claude.json`, handshakes them in parallel, and closes the tool
list at some point. Measured 2026-08-04 with 27 servers: over 6 turns, `github` made the list 4 times,
`gmail` 3, `googledrive` **never**. Capping to Grid's 3 connectors ⇒ **4/4 connected, all 164 tools**.

- `--strict-mcp-config` is only half the work — without it the document is *merged* with `~/.claude.json`
- `--mcp-config <nonexistent path>` kills the turn **before the model** → a broken write must return `null`
  to drop **both** flags

#### Browser lane (Claude only)

```
planClaudeBrowser({model, extensionState, cliSupportsChrome, cdpReady})
  extension: model is a seat (claude:*) && --chrome in --help && extension ready
             → EMPTY env + drop kClaudeRelayEnvKeys (the extension refuses an API-key session)
  cdp:       has npx + a browser → spawn Chrome --remote-debugging-port=9222
             --user-data-dir=~/.grid/app/chrome (its own profile, NOT logged in)
             → MCP entry chrome-devtools = npx chrome-devtools-mcp@latest
  none:      every outcome is logged WITH ITS REASON
```

#### Undo files the agent changed

`AgentChangesController.record(path, before, after)` — **the first `before` wins** (undo restores the
pre-agent original). `AgentChangesBar` auto-hides after 10s, with Review (per-file diff) + Undo all. Hermes
reports the path the agent typed verbatim (sometimes with `~/`) → must `expandHome()`.

### 7.3. `connectors/` — OAuth + MCP integration

**Owns:** a catalog to browse, **two** OAuth flows, the credential store, MCP servers the user types by
hand, and projecting all of it into **all three** agents so one sign-in works everywhere.

#### Path B — gateway-brokered

```
POST /v1/grid/connectors/start {"connector": "gmail"}
  → {authorize_url, pickup_code, poll_interval, expires_in}
  → _forgetLocally()  (START FIRST, FORGET AFTER — on failure the old credential is intact)
  → open the system browser
  → loop POST /poll {"pickup_code"} every poll_interval
      EVERY outcome is HTTP 200; `status` is the only signal
      pending → keep going · ready → adopt · failed/expired/consumed → stop
  → _store(token):  write tokens.json → chmod 600 → READ BACK TO CONFIRM → projectTokens()
```

> ⚠️ **`ready` arrives exactly once.** A repeat poll returns `consumed` **with no token**, and there's no
> way to get it back. That's why `_store()` writes disk *before* any state change, any toast, anything that
> could throw.

#### Path A — DCR self-serve (RFC 7591 + PKCE S256)

```
mcpAuthProbe(mcpUrl):
  1. POST <mcpUrl> with a real JSON-RPC `initialize` body (not GET — streamable-HTTP returns 405)
     401/403 → parse WWW-Authenticate · 2xx → anonymous works
  2. resourceMetadata → /.well-known/oauth-protected-resource<path> then the bare form
  3. 4 metadata URLs: oauth-authorization-server + openid-configuration,
     each as INSERT-well-known-before-path (RFC 8414 §3.1) then as append-to-tail
     — Stripe/monday.com/GitHub publish only the first form
  → has registration_endpoint → dynamicRegistration, else → preRegistered

connectDirect:
  OAuthLoopbackListener.bind()  — try 51789..51792 first, then let the OS assign
                                  bind BOTH IPv4 and IPv6 on the same port
  oauth.register(...)           — reuse clients.json only when issuer AND redirectUri both match
  PKCE (32-byte Random.secure, hand-rolled SHA-256) + a 24-byte state
  → browser → loopback callback → compare `state` BY HAND → exchange
```

#### Projection — `MarkedMapProjection`, three inviolable rules

1. **Delete by name, not by subtraction.** Only `removing` deletes. An empty store ≠ "delete everything"
   (30/07: an expired `asana` token emptied the store and swept two running connectors away with it)
2. **An entry with no marker belongs to the user** — don't edit, don't delete
3. **Nothing to write → write nothing** — avoid churning the user's file on every refresh sweep

The marker has two shapes: `InEntryMarker('_grid')` (Hermes, Claude — both keep unknown keys) and
`SidecarMarker` (Codex — measured 03/08 that `[mcp_servers.x._grid]` gets swallowed when `codex mcp add`
runs for a **different** server). The sidecar holds **names only**, never a token.

#### Automatic refresh

Scheduled **by deadline, not by polling**: take the min `expiresAt` of the refreshable tokens, subtract a
5-minute head-start, clamp to `[1 min, 1 hour]`. No refreshable token → **no timer**.

> **A failure never deletes anything** — not even a 401 — because the `refresh_token` is the one thing that
> can still recover.

#### Traps

- `null` ≠ `ConnectorTransport.none`: `null` = the gateway said nothing; `none` = the gateway asserts "this
  grant goes nowhere". Merging them would silently unlink every token written before the field existed
- `saveRefreshed` must **merge, not assign** — `/refresh` returns only credentials, an overwrite wipes
  `scope`/`account_name`/`mcp_entry`
- `bearerScheme` always writes `Bearer` even if the provider returns `bearer` — canva/cloudflare/postman
  return 401 for their own casing
- PKCE `plain` is rejected outright even if the server offers it
- `isManualAuthType` drops every `auth_type: "pat"` row at the parse boundary — a connector without OAuth in
  the backend **vanishes entirely** from the app (intended, not a bug)

### 7.4. `skills/` — folders of instructions for the agent

A skill = **one folder** holding `SKILL.md` (a front-matter card + instructions).

**Four ways in:** hand-write · upload a folder (drag & drop, `skillFolderRefusal()` checks the card has
**both** `name` and `description`) · a public catalog (**114 `SKILL.md`** bundled under
`assets/public_skill/Anthropic/`) · a chat suggestion (the "Turn this into a skill…" menu → the model
returns a ```` ```skill ```` JSON block → `SaveSkillBar`).

`copySkillFolder` **deletes `to` first, then copies** — a skill is one unit, and merging would leave orphan
files.

#### Three bugs found by reading

1. ⚠️ **"Share to all agents" can wipe out the skill itself.** `_targets` always adds `ShareTarget.all`, and
   `all.agents` **includes the current tab's agent**. On a row in the Hermes tab: `from == to`, and
   `copySkillFolder` opens with `delete(to)` → it deletes `from` too. Needs a guard
   `if (from.path == to.path) return;`
2. ⚠️ **"Reinstall Grid's skills" always installs for Hermes**, whatever tab you're on — the plane comes
   from `extensionAgentProvider` (fixed to `hermes`). Press it on the Codex tab → it writes `~/.hermes/skills`,
   re-reads `~/.codex/skills` still empty, and toasts "up to date"
3. ⚠️ **`SaveSkillBar` goes straight to `SkillAuthor`, bypassing `SkillsController`** → the skill only lands
   in `~/.grid/skills/user/<slug>` — **the library, which no agent reads**

Also: installing a public skill for a second agent is refused (`exists()` true because the library already
has it), and `SkillSource.store` ('Library') **has no tab** in the UI.

### 7.5. `plugins/` — the agent's tool backends

Unlike skills: *"Plugins give it new powers; skills teach it what to do with them."*

A thin wrapper over the agent CLI, re-reading JSON after each command (**not optimistic**):
`hermes plugins list/install/enable/disable/remove` · `claude plugin …`.

- **Codex `plugins == null` permanently** — `[plugins.*]` in `config.toml` is written by the ChatGPT desktop
  app, and there's no CLI verb to drive it
- The screen is **`devOnly`** — not shipped to real users yet, rightly, since Codex's plane is null

### 7.6. `scheduled/` — tasks on a schedule

**Schedules nothing itself** — it's a client that writes-through the CLI to Hermes's scheduler, reads back
`~/.hermes/cron/jobs.json`, and does the part Hermes doesn't: bring results into the Chat tab, an unread
badge, a desktop notification, a pinned model.

#### Creating a task — a 10-step chain

```
1. hermesModelRefusal(model)               block a Claude/Codex-seat model
2. ensureModelForSelectedGrid()            write ~/.hermes/config.yaml — SKIP THIS and
                                           every run fails with "no model configured"
3. applyBeforeSaving()                     write platform_toolsets.cron BEFORE the job exists
4. before = {existing ids}
5. hermes cron create <schedule> <prompt> --name <n> --deliver local [--workdir <d>]
6. re-read jobs.json
7. created = the new job ∉ before           ← cron create does NOT print an id
8. _pin(created.id, model)                  ← via Hermes's own Python (below)
9. projectTasksProvider.assign(jobId, projectId)
10. runNow → hermes cron run <id>
```

#### Pinning a model — the detour through Hermes's interpreter

`hermes cron create/edit` has **no `--model`** (v0.19.0), so the app resolves the `hermes` binary's
symlink, finds `python` beside it, and runs `python -c "from cron.jobs import update_job; …"`.
Re-arming is **two writes**: pin the model, then unpin (only unpinning makes Hermes re-snapshot); pin first
so a tick slipping in between still runs the right model. `TODO(BE)`: ask for a `--model` flag.

#### The delivery sweep (every 30s)

1. **`await chatSessions.restored`** — mandatory. A sweep that runs while chats are still loading creates a
   *second chat* with the same id, and today's result replaces the history
2. Scan `~/.hermes/cron/output/<jobId>/*.md`, parse the time from the **filename** `YYYY-MM-DD_HH-MM-SS.md`
3. `deliverFromAgent(id: 'task-<jobId>', …)` → chat + inbox digest + unread badge + notification
4. **`fallbackToAuto(served)`** — runs in the sweep (the one loop that runs whether or not the Scheduled
   screen is open). An empty `served` means **"not loaded yet"**, not "the grid serves nothing" — otherwise
   the first sweep after opening the app would re-point every task

#### Task power

`fullAccess` | `noCommands` → write
`platform_toolsets.cron = ['file','web','browser','skills','vision','todo','memory','session_search']` +
`approvals.cron_mode = 'deny'`.

> ⚠️ **`noCommands` doesn't stop file writes.** Hermes only asks about edits over ACP, never in cron; the
> `file` toolset bundles read+write, with no read-only half. And this is a **Hermes-wide, not per-task**
> limit.

### 7.7. `messaging/` — a config writer for the Hermes gateway

**No API, no websocket, no cloud bot.** Writes `~/.hermes/.env`, edits `config.yaml`, then runs
`hermes gateway install` + `restart`. Telegram/Discord/Slack messages **never pass through the Flutter app**.

| | telegram | discord | slack |
|---|---|---|---|
| credentials | `TELEGRAM_BOT_TOKEN` | `DISCORD_BOT_TOKEN` | `SLACK_BOT_TOKEN` **+** `SLACK_APP_TOKEN` |
| allowlist | `TELEGRAM_ALLOWED_USERS` | `DISCORD_ALLOWED_USERS` | `SLACK_ALLOWED_USERS` |
| home channel | `TELEGRAM_HOME_CHANNEL` (userId) | — | — |

**Three invariants, each once a bug:**

1. It must be **`restart`, not `start`** — a running gateway ignores `start` and won't re-read `.env` → the
   bot shows "connected" but **answers no one**
2. **`_pointAtGrid()` must run before anything** — Hermes keeps its own config; unnamed, it has no model to
   call
3. An empty allowlist is refused — an empty `.env` means **anyone** can message it

> ⚠️ **Toolset pinning was REMOVED as a product decision.** `HermesPlatformPolicy` now only does **undo**.
> A Telegram message now hits the same tools as an in-app chat, **and nobody is asked**. The bot's allowlist
> is the only gate left — it is a **security boundary**, not a convenience. `docs/messages-tab.md` §5
> describes the old behaviour and is **out of date**.

Also: tokens are plaintext in `.env`, and the **`.bak` keeps deleted tokens** (`EnvFile._write` copies the
`.bak` before **every** write, including `removeEnv`'s).

### 7.8. `network/` — the P2P grid

**Owns:** create/rename/delete a grid over the control plane, membership, reading live state from the relay,
inferring "how strong is this grid", and all of "How to use".

#### Three permission axes — often confused

| | Meaning | Gates |
|---|---|---|
| `role == admin` (`isOwner`) | Grid owner | Delete, Rename, AutoRouterCard |
| `isProvider` = `scopes.contains('provider:poll')` | **Capability**, not a role | `ProviderView` opens the join form |
| `canManageProvider` = `isOwner \|\| isProvider` | | The Members tab |

#### Overview polling

`GridPowerPill` (top bar) is the **only place that mounts the refresher**. Cadence **60s** normally, **15s**
on hover; paused when the window is hidden. Consequence: **the Settings pane doesn't mount `AppTopBar`, so
the grid-detail pane in the Grids tab doesn't refresh itself.**

- Everything derived reads via `gridOverviewSnapshot = gridOverviewProvider.select((a) => a.value)` — never
  `.asData`. Reading `.asData` zeroes the numbers on every poll cycle
- **Value equality on `GridOverview` is load-bearing** — without it, every poll hands Riverpod a new object
  ⇒ the whole derived graph recomputes, and if it lands while a screen is mounting ⇒ `setState() during
  build`

#### "How to use" — client-app configuration

`ClientAppDetector` probes: `$HOME/<configDir>` exists → `/Applications/<name>.app` →
`HostEnvironment.findExecutable()`.

| App | File written | How |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | merge the `env` block |
| Hermes | `~/.hermes/config.yaml` + `.env` | `YamlEditor` in place (keeps comments) |
| Codex | `~/.codex/config.toml` + `.env` | **re-encode the whole TOML** (loses comments/key order) |
| Buzz, OpenClaw | (disabled) | writer + snippet still compile + test |

Every write is `_backupThenWrite`.

#### Traps

- **`isPublic` is deliberately inverted**: `permissioned-providers` = **Public**, `permissioned-public` =
  **Private**. There's a "Do NOT fix this" comment
- **Rename uses a different path from create/delete**: `PATCH /v1/grid/networks/{id}` vs
  `/v1/grid/managed-networks/{id}`. `TODO(BE)`: the rename endpoint **validates nothing**
- **`kAutoModelId`**: the relay advertises a virtual `auto` model even when no node serves it
- **Hermes `toolsets:` is an allowlist, not an additive list** — the key existing means every toolset not
  named is turned off. It once left the agent only able to browse
- **Hermes `approvals.mode` is forced to `manual`** — the default `smart` lets a helper LLM auto-approve
  `rm -rf`
- The `advertises_*` flags are **tri-state**: `null` = "the relay didn't say", **not "no"**

### 7.9. `provider_node/` — what this machine contributes

Owns the engine lifecycle (`grid join` / `grid leave`), the hosted-engine catalog, probing for a running
OpenAI-compatible server, and the **Model engines** tab.

```dart
sealed ProviderRunState =
    ProviderRunIdle | ProviderRunActive(grid, log, starting, model)
  | ProviderRunStopping | ProviderRunStopped | ProviderRunFailed(message)
```

**One machine = one engine**: `canAddEngine(serving) => serving.isEmpty`.

#### Reconcile — re-adopt engines that survived a restart

Scan `~/.grid/run/engines/<gridId>/*.json` → `firstLiveRun()` picks the record whose pid is alive
(`kill -0`) → read the log tail (400 lines) → `ProviderRunActive(starting: false)`.

#### Three engine kinds

| Kind | argv |
|---|---|
| local | `join <grid> --serve <gguf> --endpoint-port <free> [--advertise-as] [--ctx-size] --name <node>` |
| external | `join <grid> --at <url> -m <model> --ctx-size 200000 --name <node>` |
| API/seat | `join <grid> --api <kind> [-m …] --name <node>` + env `{KIND_API_KEY}` |

`kApiProviders`: `openai` (key), `claude` (seat `claude` binary), `codex-cli` (seat `codex` binary).

#### Retry logic

- last log contains `'already joined'` → `_leaveEngine` then retry **once**
- last log contains `'already in use'` → rebuild args with a **new port** then retry
- `findFreePort()` binds `127.0.0.1:0` then closes — there's a race window, retry once

> ⚠️ **`grid leave <grid>` deliberately has NO `--engine`**: in remote mode the CLI keys the run record by a
> fixed engine id `remote`, while `--name` is only a display `meta_name`; `leave --engine` matches on endpoint
> URL / model / label, **not** on name. Passing `--engine <name>` once matched nothing and left the engine
> serving after the app closed.

`TODO(BE)`: a detached engine logs into `~/.grid/run/engines/` rather than through this process, so
`localProviderEndpointProvider` **stops firing** → Playground falls back to the relay path.

### 7.10. `models/` — managing GGUF

Scan `~/.grid/models`, group split-GGUF shards into one model, `grid pull` / `grid rm` / `grid ctx`, infer
`--advertise-as`, install `llama.cpp`.

**Model manager** = a 980×720 dialog, a 340px sidebar (search debounced 350ms / sort / install-filter) ⟂ a
detail pane. Suggestion by hardware: `grid device-info --json` → `POST /v1/grid/catalog {"device": …}` (the
app **interprets no field**).

#### Regressions from the split view replacing the old UI — 4 things

1. **No way to cancel a download** — `ModelPullController.cancel()` is only called from a `DownloadRow` that
   is now dead
2. **`ModelPullFailed.message` is never shown** — the detail panel catches the state and only hides the
   spinner
3. **Deleting a split-GGUF deletes only 1 shard** — the `-00002-of-00005…` shards stay on disk forever
4. **No "in use" guard when deleting** — `isModelInUse` lives only in the dead file

**Measured dead code:** `download_row.dart`, `manager_search_field.dart` (0 imports each),
`catalogModelsProvider` (only its own definition left). (`suggested_models_section.dart` — the 471-line file
this note used to name — was **deleted**.)

**`grid pull` doesn't surface the exit code** — `GridCliServiceImpl.pull` closes the stream when the process
exits, whatever the code. Consequence: a failed `grid pull` (exit 1) makes a stream that ends **normally** →
the Debug tab shows a failed download in **green**. Only `ModelPullController` survives, thanks to a
**disk-rescan** afterward.

### 7.11. `playground/` — transport + rendering (Chat's core library)

> **Playground is Chat's core library, not the other way round.**

Three transports + the whole render layer:

| Path | Endpoint | Streaming |
|---|---|---|
| chat | `POST {relay}/chat/completions` | ✅ token-by-token (`ChatSendStreaming` **cumulative**) |
| responses (Codex seat) | `POST {relay}/responses` body `{model, instructions?, input, stream: true, store: false}` | ❌ **drains fully, then yields one `ChatSendSuccess`** |
| media | `POST {relay}/media/image/generate` \| `/edit` \| `/video/i2v` | `ChatSendGenerating` (idle timeout 5 min) |
| local smoke test | `POST {localBaseUrl}/v1/chat/completions` | ✅ |

**A key fallback:** if **no `data:` line** appears, parse the whole body via `chatStreamWholeBody` — for a
relay that ignored `stream: true`.

#### Rendering one reply

```
parseMessageSegments(text)     ← _mediaPattern catches a fence BEFORE anything, even an unclosed one
  → one SelectionArea for the WHOLE message  (not MarkdownBody(selectable: true) —
     that builds an EditableText per rich-text node)
  → _splitByTable on the delimiter row |---|:--:|  (not on a bare |)
     a run with a table → full column · a run without → maxWidth 760
  → MarkdownBody(gitHubFlavored, softLineBreak: true, builders: {'pre': CodeBlockBuilder})
     language == 'chart' && !openFence → ChartSpec.parse → MessageChart (pure CustomPaint)
     an unclosed fence → HIDE Copy + TURN OFF syntax highlight
  → media: LocalMediaView / InlineImage(CachedNetworkImage) / InlineVideo(media_kit) / InlineAudio
```

**Invariant:** `ChatSendStreaming.text` is **the whole** reply so far; `ChatDelta.text` is a **fragment**.
Confusing the two doubles the text.

**Risks:** an image that fails to read is **swallowed silently** (the UI still shows it in the user bubble);
images are read with `readAsBytesSync` + `base64Encode` **on the UI isolate**; **history is uncapped** — the
whole transcript goes every turn, including each file's 20,000-char `promptBlock`.

### 7.12. `projects/` — a folder the agent may read

**Entirely app-owned — no CLI, no HTTP.**

`Project{id, name, path, instructions, memory, pinned, agent?, model?}` → `~/.grid/app/projects.json`.

**`projectStandingBrief(project)`** = `instructions` + `"Remember about this project:\n- <fact>"` — the
**only contract** by which memory actually reaches the agent, and it **rides only the session's opening
turn**.

**Probe whether a folder still exists:** `Future.wait` in parallel, 5s timeout, **timeout/exception ⇒ treat
as PRESENT** (saying "your folder vanished" over a slow stat is a worse lie). Previously
`Directory.existsSync()` sat in **4 `build()`s** and blocked the UI thread for seconds on a network share —
for a badge.

A rail of 4 cards (Instructions / Context / Scheduled / Memory), **keyed by project id** so switching
selection doesn't carry half-typed notes to another project.

⚠️ Naming trap: `agent_workspace.dart` lives in `features/projects/logic/` but is about the **agent's own**
workspace (`~/.grid/app/agent-workspace`), *not* a user project.

### 7.13. `auth/` — device login

`grid --remote login --no-browser` → a parser takes the first line starting with `http` as the URL and the
`Code:` line as the user code — **by shape, not by label**, so changing the CLI prompt's wording doesn't
break login.

`selectedNetworkProvider` resolves in order: `_selectedId` (session) → `chatPrefs.networkId` →
`activeRemoteGridProvider` → `creds.active`. `select()` writes `chatPrefs`, **never** `~/.grid`.

**Session expiry:** `CliResult.sessionExpired` is a **string-match on four English sentences** — a CLI
wording change makes the app silently stop detecting it. `onExpired()` → try `grid sync` (reuses the session
token, no browser) → on failure → `needsLogin` → `LoginScreen`.

Logout calls `shutdownServing()` **first** — no engine serving after the account has left.

### 7.14. `onboarding/` — preflight → installer → choice

**Preflight** (every launch): `grid --remote --version`.
A **negative** exit → `_signalError` (`-9` = Gatekeeper/AMFI blocking an unsigned/quarantined helper).
A positive exit → `diagnoseCliFailure` keeps the **last non-empty line**, not the whole traceback.
An empty `stdout` **is not an error** (a source checkout exits 0 without printing a version).

**Installer** — 2 phases, stopping at the first failure: `_ensureGrid()` (`grid sync` if there's no grid) →
`_installAssistant()` (installs the assistant; passes `includeEngine: false, includeModel: false`). Each
row's state is **inferred from the real machine**, not from a flag the installer set.

⚠️ `_installAssistant` passes `includeEngine: false, includeModel: false` but **leaves `includeMedia` at its
default**. Re-enabling `kMediaSetupEnabled` would have the first-run installer quietly pick up
`engine install comfyui` + `engine pull image_generation` (several GB) — exactly what this screen promises
not to do.

**Choice screen:** an already-signed-in CLI seat · "Run a model on this computer" (macOS only) · API-key
disclosure · "I'll set this up later".

### 7.15. `auto_router/` — the virtual `auto` model

The only domain that talks to the control plane **via the CLI** (`grid router …`) and the **only place in
the app that parses stdout** instead of reading `~/.grid` — because the router config lives on the control
plane.

**Advisor chain** = the chain of cloud AIs asked to rank the grid's models for each request.
`kMaxAdvisors = 3`, order-preserving, with promote.

**Mandatory order:** `set-advisors` **before** `enable` — the control plane refuses `enable` with no
advisors.

`autoEnableForOwner()` no-ops when `config.enabled || config.hasAdvisors` — routing is either on **or** the
owner deliberately turned it off (advisors survive `disable`). Both are the user's state.

### 7.16. `command_palette/` — ⌘K

Sealed `CommandItem`: `OpenChatCommand` · `NewChatCommand(project?)` · `OpenTaskCommand` · `AddProjectCommand`
· `OpenSettingsCommand` · `GoToCommand(section)`.
Ranked in 3 tiers: label starts with the query > has a word starting with the query > contains the query.

- **`chats:` must be `liveConversations(...)`** — archiving a chat should also make it vanish from search
- `kMaxMatchesPerGroup = 8` keeps the cost flat with a long history (`ListView(shrinkWrap: true)` lays out
  **every** row per keystroke)
- **Pop first, act after**, using `navigator.context` — `AddProjectCommand` opens a dialog that must attach
  to a navigator outliving the palette
- ⚠️ `AppTheme.watch` is **entirely absent** from both files → a theme-flip bug

### 7.17. `prompts/` — the `/` library

Deliberately simple — just named boilerplate, quite unlike a skill. `slashQuery` requires a leading `/` and
the rest to contain **no whitespace** (`/a b` → null, the user is writing a real sentence).
`edit()` **overwrites** the whole box (unlike `_insertMention`, which inserts at the caret).
Names are slugged **the moment the file is read** — the library saves the slug-fixed name without waiting
for the user to reopen it.

### 7.18. `appearance/` — theme, font, detail mode

No `logic/` — everything reads/writes `chatPrefsProvider`.

- `ThemePreviewTile` draws a `_MiniApp` using **real tokens** at that brightness via `AppTheme.as` — not a
  hardcoded grey, so the preview breaks exactly when the palette changes
- `_SizeField._commit()` runs on Enter or **on losing focus**, not per keystroke — typing "9" on the way to
  "19" would resize the whole app and shift the very field being typed in
- `_TypePreview` builds the **real widget** `MarkdownCodeBlock` — the same thing the chat transcript builds
- **The default theme is `light`, not `system`**
- ⚠️ **Only macOS has a font list** — the `grid/fonts` channel is only implemented in `AppDelegate.swift`.
  On Windows/Linux the picker offers only "System"

### 7.19. `node_setup/` — the machine-setup wizard

`buildSetupPlan` is a **pure function**:

| Condition | argv | isDownload |
|---|---|---|
| `!engine.llamaInstalled` | `engine install llama.cpp` | |
| `!hasModels` | `pull <spec>` | ✅ |
| `!installedAgents.contains(hermes)` | `[]` (the app installs it itself) | |
| `!hasMediaEngine` (off) | `engine install comfyui` | |
| a bundle is missing files (off) | `engine pull image_generation` | ✅ |

**"Missing" is measured against Grid's engines, not the machine**: a machine that already has Ollama is
still planned to install `llama.cpp` — previously an empty plan left the grid with no model.

**Auto-host** runs only **after the background model download finishes**, never at launch
(*"a launch hook here is a regression, not a convenience"*), and **never puts the machine on a public grid**.

`kMediaSetupEnabled = false` — the whole ComfyUI branch is off behind one constant; the code still compiles
+ tests.

### 7.20. `debug/` — the command log (dev-only)

A ring buffer of **200 entries, RAM only, current session only**. What survives a crash is the file in
`~/.grid/logs` — which is the whole reason the "Open logs" button exists.

**Copy to re-run** (`logAsCommand`):
- HTTP → `curl -sS -X POST '<url>' -H "Authorization: Bearer $GRID_API_KEY" -d '<body>'` — **the variable
  name, never the value**
- CLI → `KEY="$KEY" grid --remote join …`, the prompt via a `<<'GRID_PROMPT'` heredoc (the opening tag is
  **quoted** so the shell doesn't expand `$`/backtick)
- `#` lines carry the outcome + warnings "the body was truncated" / "this env var is needed"

`_WhichGridCard` shows `gridPathProvider` + `GRID_BIN` + preflight; Recheck invalidates both →
**rebuilds the whole decorator stack**.

### 7.21. `app_update/` — Sparkle

The CI bakes the feed `https://github.com/<repo>/releases/latest/download/appcast-{arch}.xml`.
The `{arch}` token exists because the app is **one universal binary** but the two DMGs differ in the arch of
the **`grid` sidecar inside** — the wrong feed would hand an arm64 DMG to an Intel machine.

**The `_answered` flag fixes a real copy bug:** Sparkle reports "no update" **twice** — once via
`onUpdaterUpdateNotAvailable`, and again down the **error channel** with the message `You're up to date!`.
Unguarded → a red toast "Couldn't check for updates: You're up to date!". The fix keys on **order**, not
message (string-matching is only right in English).

A local build is always `UpdateUnsupported` (`GRID_APPCAST_URL` is baked only in `release.yml`).
`isSupported => Platform.isMacOS`.

### 7.22. `review/` — a project's diff, beside the conversation (46 files, the largest domain)

**Owns:** reading a Git repo into something viewable, stage/unstage, commit, push, per-line comments, and
having the model write a commit message. **Doesn't own:** chat, project, agent — it is *handed* a folder and
*returns* a message (`onAskAgent`). The wiring is in `chat/presentation/panel_feature_view.dart`.

It lives in a panel tab, not a screen of its own: review is work done **while** the agent runs — going to
another screen to see what it just wrote means leaving the very chat that asked for it.

#### `ReviewScope` — sealed, 6 branches, each **a different pair of Git commands**

Not filters over one shared answer (`review_scope.dart`):

| Scope | `_range()` | Source of the file list |
|---|---|---|
| `LastTurnChanges` | `HEAD` | `status`, filtered by paths the agent just changed |
| `UncommittedChanges` (default) | `HEAD` | `status` |
| `UnstagedChanges` | *(empty)* | `status` |
| `StagedChanges` | `--cached` | `status` |
| `CommittedChange(sha)` | `null` → use `git show` | `show --name-status` |
| `BranchAgainst(ref)` | `<ref>...HEAD` | `diff --name-status` |

Two getters block meaningless controls: `canStage` (a commit/branch is settled — a tick there is a button
that does nothing) and `showsUntracked` (a file Git never knew is in no commit, index or branch).

`BranchAgainst` uses **three dots** (`merge-base`), not two — otherwise a commit that landed on `main`
*after* this branch forked would read as "this branch deleted them".

#### `review_argv.dart` — every Git argv here, as tested pure functions

*"A wrong flag fails exactly like an empty repo"* (§7 conventions). Six things learned by bug:

- **`git show` must have `--format=`** — without it it prints its own commit header above the diff, and the
  first "file" parsed is the subject line
- **`status --porcelain=v2 -z`, not v1.** v1 quotes/escapes non-ASCII paths → **Vietnamese filenames come
  back as garbage**, and its rename form is ambiguous. The price: a rename's original path is **a separate
  NUL-terminated field after the record**, so you can't split-then-map straight through
- **A rename must pass BOTH paths.** Give only the new path and Git has nothing to pair it with and reports a
  file appearing from nowhere — **every line "added"**, i.e. the opposite of a rename's meaning
- **Untracked files use `diff --no-index -- <nullDevice> <path>`.** A plain `git diff` **prints nothing** for
  them. And `--no-index` signals "the two sides differ" with **exit code 1** — treating that as an error
  leaves every new file's diff **blank forever**
- **`unstage` uses `reset`/`rm --cached`, NOT `git restore --staged`** — `restore` is Git 2.23+, the app
  supports down to 2.20. A repo with no commits has no `HEAD` to reset against → drop from the index instead
- **"Stage all" lists **the visible paths**, not `git add -A`.** Under a narrow scope (last turn),
  "everything" means the files on screen — `-A` would **quietly slip in work the user never saw**. Batched 50
  paths per command because the Windows command line caps at 32KB
- **`kLogFieldSeparator` is `` ` ``** (a backtick), not `|` or a newline: every printable character has, at
  some point, appeared in somebody's commit message

#### Layering

```
ReviewController (AsyncNotifier.family by folder)
  └─ ReviewLoader   ← reads: knows the ORDER to ask in and what to do with the answers
  └─ ReviewActions  ← writes: stage/unstage/commit/push + patch one file
       └─ GitRunner (infrastructure) ← only knows how to spawn git
```

`ReviewLoader` sits outside the controller so it can be tested with a fake runner and no Riverpod, and
outside `infrastructure/` because the shape it returns is **review's**, not the CLI tier's.

- `branch` / `HEAD exists?` / `upstream` / the file list are asked **in parallel** (`(a, b, c).wait`) — the
  screen doesn't wait on three sequential round-trips
- **Untracked files are line-counted from DISK**, since `--numstat` says nothing about them. A new file
  showing "0 lines" understates exactly the change the user is about to commit. Cap 4MB → report binary
  (honest about not knowing, better than wrong)
- `refresh()` **keeps the visible list**, doesn't fall back to a spinner — refreshing to blank while a file
  is open loses your place every time the agent touches a file
- ⚠️ **`build()` only `watch`es `reviewLastTurnPathsProvider` WHEN the scope is `LastTurnChanges`.** An
  unconditional watch means **6 `git` commands every time the agent writes a file** — a spawn storm behind a
  list nobody is looking at

**Three self-re-read paths, and they cover each other's gaps:**

| Path | Catches | How the cost is bounded |
|---|---|---|
| `_followDisk` — listens to `fileChangesProvider` | the agent writing files, the Files panel's watcher | the burst is pre-coalesced, **plus** a 400ms quiet → 12 files written = **one** read |
| `_ReviewTab`: an agent turn **ends** while Review is showing | **commit** — which disk can't report, because a commit **writes no file in the working tree** even though git changed completely | at the end of the turn, not per write |
| `_ReviewTab`: the tab **comes back into view** | a `git commit`/`checkout` typed by hand in the Terminal tab next to it; anything that happened while nobody looked | once per return, no polling |

> "Showing" = `PanelTabVisible.of(context)` **and** the panel is open — a closed panel keeps its tab in the
> tree, so the tab's own flag is only half the answer.

#### `ReviewState` — 4 branches, because **3 of them the user can do something about**

`ReviewNeedsGit` (→ the Git screen) · `ReviewNotARepo(folder)` (→ offer `git init`) · `ReviewFailed(message)`
· `ReviewReady(snapshot)`.

`friendlyGitFailure()` translates 8 families of Git error into actionable sentences — **and the raw text
always goes to `appLog` alongside** (§6: humanising is never the only record). Notably: a credential error
says *"push from Terminal once, then the machine remembers and this button works"* — because **this very app**
is what turned the prompt off.

#### Commit

`CommitState` sealed, 4 branches; `CommitFailed` carries a **`committed`** flag — a push that fails after a
successful commit, read as "nothing happened", makes the user **commit the same work twice**.

- `commitArgv` **deliberately has no `-a`** — staging is the user's decision, made file by file on this screen
- `includeUnticked` stages the rest **inside `run()`**, so stage + commit + push is **one run with one error
  to report**
- A separate `pushOnly()` — for work already committed in the terminal, or a prior failed push, waiting for
  it; and **nothing left to describe**
- `setUpstream: snapshot.upstream == null` — a branch that never pushed makes Git refuse a bare `push`

**`CommitMessageWriter`** — a blocking `chat/completions` call over the shared `ChatTransport`, with the same
`resolveOneShotTarget` as the skill generator (the local engine if serving, else the relay). It caps the
patch at **12,000 chars**, and **says so when it truncates** (`[… the rest of this change is not shown]`).

> ⚠️ **`_patch()` reads TWICE, not once.** `git diff` in every form **says nothing** about a file Git doesn't
> know, so a change that is *entirely new files* comes back empty and the button answers "nothing to
> describe" over a visible +32 list.

`tidyCommitMessage()` is pure and **deliberately lenient** — a model returns a fence around the whole answer,
a `Commit message:` prefix, a subject in quotes, a period on the first line (a commit subject carries no
period).

#### Reading the diff

`DiffViewPrefs{layout, wrap, ignoreWhitespace, collapsed}` — **one setting for the whole app**, not
per-folder: this is a preference about *reading diffs*, not a fact *about a repo*.

- **`kSplitDiffFrom = 620`** — below it each column is under 280px. The toggle **isn't offered**, and a choice
  made on a wide window **quietly draws unified** until there is room, rather than mincing every line into
  three
- **`wrap` defaults on** — the panel is 420–760px wide, and a line you must scroll sideways to finish is a
  line you don't finish
- **`ignoreWhitespace` is Git's `-w`**, not a post-filter: it drops **a whole line** that differs only in
  whitespace
- **`reviewOpenHunksProvider` is a set of EXCEPTIONS, not the truth.** "Collapse all" is a flag; a hunk opened
  by hand afterward must survive without turning the flag off for every other hunk. `hunkIsOpen()` is pure

**`CodeHighlight` has a memo, and that is the condition for the diff to scroll at all.** Measured: one line of
Dart costs ~170µs to tokenise; the diff draws line by line → one screen ≈ **8ms of a 16ms frame budget**,
spent again on every rebuild and every scroll. Keyed by *text + language + brightness + base style*; capped
at 4,000 entries; **a grammar that throws is remembered too**, so a line that can't be highlighted isn't
re-parsed every frame.

#### Per-line comments

`ReviewComment{path, side, line, text, code}` — **kept in the session, written nowhere**, and the UI says
"Local comment" so no one waits for a colleague to reply.

`DiffSide` is mandatory: a deleted line exists only in the old file, an added line only in the new — "line 32"
alone names **two different lines**. For a context line, **the new file wins**.

`commentsPrompt()` is pure, and **is the whole feature** — it tells the agent to **re-read the file around the
quoted line before editing**, because by the time the agent reads, its own earlier edit has already pushed
everything below line 32 elsewhere.

### 7.23. `terminal/` — a real shell in a panel tab

8 files, ~931 lines. `flutter_pty` + `xterm`. Pty details in §4.6.

**`TerminalSession` is deliberately NOT a Riverpod notifier** — several are open at once and the panel shows
one, so they are *values* a controller holds in a list. What they can't do is publish themselves: `onChanged`
is how the controller hears that a shell has started or died.

It **holds the `Terminal`** (the emulator) rather than rebuilding it each frame — **the screen IS the state**:
the scrollback (10,000 lines, like VS Code), the cursor, the half-typed command. A widget that owned it would
lose all of it on every tab switch.

**A terminal belongs to a TAB, not a folder.** Two Terminal tabs are two shells even in the same project. And
**the folder is locked when the tab opens** — a running shell can't be moved, `cd` is the user's job.

⚠️ **`endSession` is called from `PanelTabs.close()`, not a watcher.** A watcher only runs while someone is
looking — but this has to happen **even when the user closes a tab on their way out of Chat**. An orphaned pty
is a process the user can no longer see, let alone stop.

⚠️ **`_TerminalTab` must carry `ValueKey(tab.id)`** — same widget type in the same slot, and Flutter hands
tab two's id to tab one's element, so the new tab shows the old tab's screen (or nothing).

`ShellState` sealed, 4 branches; **`ShellExited` is not an error state** — leaving a terminal is how a
terminal ends. `restart()` **keeps the scrollback** above: the transcript of what just broke is usually the
very reason the user reopened it.

### 7.24. `files/` — browse and read a project's files

15 files, ~3,151 lines. A directory tree + breadcrumb + viewer, in a panel tab.

- **`filesBrowserProvider` is a family over TAB id**, not panel: two Files tabs are two places in the same
  project; sharing one selection would make the second tab meaningless — a click anywhere moves both
- **`filePreviewProvider` is `autoDispose`, and the second reason is the main one**: **the agent overwrites
  these very files while they are on screen**. A cached read would silently show yesterday's copy of a file
  that changed a second ago
- Caps: **1MB** / **2,000 lines**. The viewer lays out in one pass (no virtualisation) — which is what lets a
  whole file scroll and select as one block. A truncated file **says so**
- `decodeFilePreview` is pure: sniff the first 8KB for a NUL byte to decide binary; decode `allowMalformed`;
  **a trailing newline ends the last line rather than opening an empty one** — otherwise every well-formed
  file shows a ghost line at the bottom
- `reveal(path, root)` opens every ancestor folder, going **down from root** rather than up from the file:
  the root's separator is what the platform wrote, and reassembling from segments would lose it
- **Markdown has two modes, and "rendered" is the resting one.** `showSource` rides the **tab**, not the file
  — someone wanting raw keeps getting raw as they click down a whole docs folder
- `file_kind.dart` is pure string work: **`FileGlyph` (what to draw) split from `FileAccent` (what colour)** —
  a dozen languages share one glyph, a different dozen share one hue. Splitting them is what stops it becoming
  one-enum-value-per-extension
- The tree is hideable (`showTree`), same reason as Review's file list: a panel docked at 420px is already
  short on width

### 7.25. `git/` — install & choose Git (3 files + the seam in `infrastructure/cli`)

The Settings ▸ Coding ▸ Git screen. Mechanism in §4.6; here only the UI/controller.

`GitInstallState` sealed, 4 branches. `GitInstallDone` carries a **`GitStatus`**, not a finished sentence —
the same outcome must read differently: a re-check that **finds nothing** still ends perfectly and **must not
be reported as success**.

> It exists because the probe answers in ~10ms — **under a frame**. On a machine where Git hasn't changed,
> pressing the button moves nothing on screen, and **an outcome-less control reads as a dead one**.

`gitReadyProvider`: **not resolved yet = *unknown*, not *absent*** — so nothing tells the user to go install
Git while the probe is still running.

### 7.26. `overlord/` — ⚠️ FAKE + UNREACHABLE

> **Two problems, both worth stating:**
> 1. **All the data is FAKE.** `overlordRepositoryProvider` hard-binds `FakeOverlordRepository`, running on a
>    hardcoded `seedFleet()` — 4 GPUs with **internal IPs, a username (`samcardillo`), and real pids
>    (750284, 1190474) of someone else's machine**. Shipping this to prod is a leak.
> 2. **The screen CANNOT be opened.** There's no `ShellSection.overlord`, `section_view.dart` doesn't map to
>    it, and grep across the whole repo (including `test/`) returns 0 results. **20 files, 1,417 lines of dead
>    code.**

The seam is well-designed (`abstract interface class OverlordRepository { Stream<OverlordSnapshot> watch(); }`)
— but nothing is plugged in. `StoragePanel` and `OrchestratorPanel` are "coming next" stubs, with two
deliberately inert `GhostButton`s. The whole feature has **not one `AppTheme.watch`**.

### 7.27. `data_sync/` — Sync & Backup (new domain)

**Owns:** encrypted backup and restore of this machine's app-owned data to a control-plane server. Maps to
`ShellSection.dataSync` ("Sync & Backup"), Settings ▸ Personal. Driven by `syncControllerProvider`
(`SyncController`), logic in `sync_bundle`/`sync_envelope`/`sync_merge`/`sync_state`/`sync_client`/
`sync_controller`/`sync_workspace`/`sync_keyring`.

`upload()` packs the machine's data — chats (`~/.grid/app/chats/`), prompts (`prompts.json`), projects
(`projects.json`), and media under `~/.grid/outputs/` — into an encrypted envelope. `download()` decrypts and
**merges** an incoming snapshot with local state, **backing local up first** into `~/.grid/app/backups/<stamp>.zip`.
`~/.grid/app/sync_state.json` is the marker read to warn that the cloud has moved on. Each backup version is
password-protected (envelope crypto handles sealing/unsealing media; `sync_keyring` holds the key material).

### 7.28. `feedback/` — user feedback submission (new domain)

**Owns:** capturing user feedback with optional diagnostic logs. `feedbackControllerProvider`
(`FeedbackController`); files `feedback_controller`/`feedback_draft`/`log_bundle`/`feedback_diagnostics`/
`feedback_dialog`/`attach_logs_field`. There is a matching `FeedbackClient` in `lib/infrastructure/api/`
(`HttpFeedbackClient`, `POST /v1/feedback`).

`FeedbackController.send()` submits to the API, logs both success and failure to the app log, and stores a
failed payload in a `FeedbackOutbox` for manual recovery. The dialog shows a plain error; the Debug tab gets
the raw response. Logs auto-attach (zipped) via an optional `logsZip` when the user opts in.

### 7.29. `code/` — shared repositories on the grid (new half of the app)

**Owns:** the whole Code half — shared projects a grid hosts, read as conversations, where a member posts a
coding task and a teammate's machine runs an agent on it. Reached by the **Home/Code switch** at the top of
the sidebar (§3), which mounts `CodePane` in place of the whole Home pane. **Developer-only** for now (the
production relay has no projects plane).

Everything talks to the control plane via `grid project …` / `grid task …` (all built in the pure, tested
`code_argv.dart`), and `--grid <grid> --json` is passed on **every** call so a screen open while the user
switches grids can't silently act on a different one.

#### A project reads as a conversation

`ProjectView` (`project_view.dart`) is laid out **like the chat half** — history above, composer below —
because it is the same act: you say what you want, and a computer does it; the difference is only *whose*
computer. The tasks are the turns, oldest at top and newest at bottom (`TaskTranscript`, over the grid's own
`created_at`-ascending order), rendered in the **shared transcript shell**
(`lib/features/playground/presentation/transcript_view.dart`, `TranscriptView`/`TranscriptRow`). You ask for
the next task in a chat-style composer (`TaskComposer`).

The project's **header sits in the top bar** (`project_header.dart`, shown via `codeProjectIsOpenProvider`),
the way an open chat's header does — no headline inside the pane; the transcript starts against the bar's
edge.

#### The workflow is automatic — `ProjectFlow`

`projectFlowProvider` (`project_flow.dart`, `NotifierProvider.autoDispose.family<ProjectFlow, …, String>`)
does around each send what a person used to remember to do in order:

1. **Before the task**, catch up: bring the trunk into this member's branch (`grid project check` then
   `integrate`), so the agent builds on the team's latest — which is also what lets the later publish be a
   fast-forward.
2. **After it completes**, publish: move the trunk to the result (`grid project promote <id> <member_key>`).
3. **Once it has shipped**, refresh the working copy the app keeps at `~/.grid/app/code/<project>`
   (`grid project clone`), so the code on disk is the code that just landed.

`submit()` puts the task on screen as an `OutgoingTask` at the foot of the transcript **before** the grid has
taken it (catch-up + create + status re-read are three CLI round-trips, and holding the paragraph in the
composer for all of them made sending look broken). Nothing here throws — a refusal lands on the outgoing
turn with a "Send it again" button.

> ⚠️ **Publish has no undo, and the flow does it with no review.** Every task a member runs lands on the
> team's `main` the moment it finishes — the asked-for trade (a project used like a chat), guarded only by the
> relay's fast-forward-only refusal.
>
> **TODO(BE): the watch is client-side.** Completion is noticed by this controller polling the task list, so
> a task that finishes after the user leaves the project (or closes the app) isn't published until they open
> it again. The durable place for "promote on completion" is the relay.

#### The side panel — `PanelHost.code`

A **right-hand panel** (Files / Review / Terminal) docks beside the project via the shared panel system, at
`PanelHost.code`. `codeSidePanelOpenProvider` is `panelOpenProvider(PanelHost.code)` under Code's own name —
the panel beside a project is the same panel as the one beside a chat, tabs, launcher and all. `ProjectView`
lays it out with the shared `resolveSidePanel` / `PanelMainSlot` / `PanelDockSlot` / `PanelFloatSlot`, so it
docks, slides, resizes and expands here exactly as it does beside the chat. It only earns its place once the
project has code (`openProjectHasCodeProvider`) and only when the user asks
(`_SidePanelToggle` in the top bar). `code_panel_feature_view.dart` is Code's copy of the one-file mapping
table (the exemption `section_view.dart` and `panel_feature_view.dart` already take), rooted at the project's
checkout rather than the chat's workspace. Review's "Ask the assistant" offers a message to the task composer
via `codeComposerPrefillProvider` — offered, not sent, so a panel never spends a task slot on a turn the user
never wrote.

The `CodePane` screen has its own ordered empty states, none of them blank: the grid tool may not know about
shared projects at all (`CliTooOldView`), no grid may be selected (`_NoGrid`), no project may be open
(`_NoProjectOpen`), or the open project may have no code yet (`_NeedsImport` → "Bring in a repository").

---

## 8. End-to-end: one chat turn

```
[1] User types into the composer
    chat_composer.dart → ComposerKeys._onKeyEvent
      Enter (no Shift) && canSend → onSend()
      SWALLOW Enter regardless — a turn that couldn't send mustn't drop a stray line break

[2] chat_view.dart  _send(modality)
      messageWithSnippets(message, _snippets)      ← highlighted runs FOLDED INTO the text
      captureTerminalContexts(attached, sessions)  ← CAPTURE THE TERMINAL HERE, not earlier
                                                     (empty terminal → dropped, no empty block sent)
      → chatSessionsProvider.notifier.send(network, model, message, modality, attachments, files, contexts)
      dismissedTerminals.clear()                   ← the ✕ belongs to the draft; draft over, effect over

[3] chat_sessions_send.dart  send()
      busy? → _enqueue(QueuedTurn) and RETURN
      approvalFor(target, chatPrefs.approval)           ← read ONCE
      buildUserTurn(...)  → images written to ~/.grid/outputs
      _commit(phase: SendBusy)                          ← WRITE DISK BEFORE SENDING
      viaAgent = agentAnswersTurn(modality, hasAttachments, agentInstalled)

[4] Lane per project: conversation.projectId != null && _laneBusy(lane) → into _agentQueues[lane]
                      (_QueuedBubble "Finishing another chat in this project…")
                      a chat outside any project: no lane → runs at once

[5] _dispatch()  → agentChangesProvider.beginTurn(id)     ← the mark "this turn starts here"
                  the Stopwatch starts HERE (not at send — time in the queue doesn't count)
                  _senderFor(viaAgent, agent)             ← the agent fixed per the chat's project

┌─────────────────────────────── BRANCH A: RELAY (no agent) ─────────────────────────────────┐
│ [6a] DefaultChatSender.send()                                                                │
│      isResponsesOnlyModel(model) ? POST {relay}/responses : POST {relay}/chat/completions     │
│      _messagesFor(history): system prompt + each turn via messageForModel                     │
│                             + each file's promptBlock + base64 image data URIs                │
│      commandLogProvider.begin(http, …) → Debug tab + app_https.log                            │
│ [7a] HttpChatTransport.stream — SSE, `data:` → chatStreamDelta → ChatDelta(fragment)          │
│      accumulate into a StringBuffer → yield ChatSendStreaming(WHOLE text so far)              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────── BRANCH B: HERMES (ACP, long session) ─────────────────────────┐
│ [6b] HermesChatSender.send()                                                                 │
│      agentRuns.reset(chat)  ← SYNCHRONOUS, BEFORE ANY await (feed keyed by conversation)      │
│      hermesGridLink.point(network, model)                                                    │
│        → ClientAppConfigurator.apply → ~/.hermes/config.yaml (+ .bak)                         │
│        → ensureRuntimeSupport() fire-and-forget · cron.followModel(model) re-arm             │
│      _sessionFor(key: networkId|model|conversationId|workdir)                                │
│        continue? → send only history.sublist(seen)                                           │
│        fresh?    → close() the old, _makeRoom() (LRU 5 PROCESSES), Process.start(hermes acp)  │
│ [7b] Handshake: id 0 `initialize` → id 1 `session/new {cwd, mcpServers: []}`                  │
│      mcpServers EMPTY — Hermes's MCP comes from config.yaml                                  │
│      empty sessionId ⇒ complete with an error at once (retryable: false)                      │
│ [8b] session.approvalMode = … (the mode at Send) → `session/prompt`                           │
│ [9b] session/update:  tool_call → activityLog.upsert                                          │
│                       agent_message_chunk → HermesAcpMessage (DELTA — sender write() accrues) │
│                       plan → planLog.replace (replaces the whole plan)                        │
│      permission request → decideHermesPermission → AgentPermissionCard pinned above composer  │
│      edit → agentChangesProvider.record(before, after) → AgentChangesBar (real undo)          │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────── BRANCH C: CODEX (exec, 1 process/turn) ────────────────────────────┐
│ [6c] codex exec [resume] --json --skip-git-repo-check                                        │
│        -c sandbox_mode="danger-full-access"  ← asks NO ONE                                   │
│        -c model / model_provider / model_providers.grid-app.{name,base_url,env_key,           │
│           wire_api="responses", supports_websockets=false}                                    │
│        (resume ? <threadId> : -C <workdir>)                                                   │
│      env {GRID_APP_API_KEY}  ← NOT GRID_API_KEY: Codex loads ~/.codex/.env and that           │
│                                dotenv WINS over the parent process env                        │
│      prompt over STDIN (avoids argv overflow when replaying history)                          │
│ [7c] parseCodexEvent: agent_message (WHOLE text) · command_execution/web_search/mcp_tool_call │
│                       · todo_list → plan · file_change (only when status == completed)         │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────── BRANCH D: CLAUDE CODE (-p, 1 process/turn) ─────────────────────────┐
│ [6d] planClaudeBrowser() → lane extension / cdp / none (every outcome logged WITH ITS REASON) │
│      ClaudeTurnMcpConfig().write(extra) → ~/.grid/app/claude-mcp-config.json                  │
│        read ~/.claude.json, keep ONLY entries marked `_grid`, + browser extra                 │
│        write fails → null → DROP BOTH FLAGS (a nonexistent path kills the turn)               │
│ [7d] claude -p --output-format stream-json --include-partial-messages --verbose               │
│        --permission-mode bypassPermissions --model <m>                                        │
│        [--chrome] [--mcp-config <p> --strict-mcp-config] [--resume <sid>]                     │
│      env: claudeCodeEnv(...) — ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL/…                  │
│           lane extension → EMPTY env + dropEnvironment: kClaudeRelayEnvKeys                    │
│      prompt over STDIN                                                                        │
│ [8d] ClaudeStreamParser (stateful):                                                           │
│        stream_event.content_block_delta.text_delta → _partial → ClaudeMessageEvent(WHOLE)     │
│        assistant.text → clear _partial, push _completed   ← stops double-counting             │
│        tool_use TodoWrite → plan · Write/Edit → ClaudeFileWriteStarted                        │
│        result → WINS ABSOLUTELY over any text assembled from blocks                            │
│      ClaudeFileWriteStarted → _readNow(path) SYNCHRONOUS (await would read the write's result) │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

[10] Agent calls a connector tool?
       → POST http://127.0.0.1:<port>/c/<connector>/mcp  (ConnectorBridge)
       → read a FRESH token from tokens.json (no cache) → _fresh() renew if needed
       → transport mcp?  McpProxy.forward → provider (attach credential headers, unwrap the last SSE `data:`)
         transport rest? RestInvoker → build the HTTP from a template, check `required` here

[11] chat_sessions_settle.dart  updates.listen — fold the sealed ChatSendUpdate
       ChatSendGenerating  → withPhase(SendGenerating)
       ChatSendStreaming   → firstToken = clock.elapsed (first non-blank text)
                             withPhase(SendStreaming(text))  ← text is the WHOLE thing, UI REPLACES not appends
       ChatSendAgentSession→ remember the sessionId
       ChatSendSuccess     → append the reply, _commit(SendIdle), _adoptAgentName, _announceTurn
       ChatSendFailure     → KEEP the streamed part (partial ?? SendStreaming.text)
       Every update checks _find(id) == null → a chat deleted mid-turn is dropped, not resurrected

[12] _finish(id) → _releaseAgentSlot → _drainQueue(id) FIRST; only an empty queue then _advanceGoal

[13] Render: _Transcript caches the widget by the IDENTITY of a ChatMessage
       → MessageContent → parseMessageSegments → SelectionArea → MarkdownBody
       → ```chart fence → ChartSpec.parse → MessageChart (CustomPaint)
       → media → InlineImage / InlineVideo (media_kit) / InlineAudio

[14] _announceTurn → notificationIsWorthIt(appFocused, userIsLookingAtIt) = !(both)
       → DesktopNotification(opens: conversation.id) → click → revealChat()
```

---

## 9. Design system

`lib/shared/theme/app_theme.dart` (**~1,423 lines**) is the **whole** system.
Canonical spec: `docs/design-system.md`.

### Four inviolable rules (§0)

1. **No borders. Depth comes from fill + shadow.**
2. **The label sits above the field, never floats.**
3. **A corner-radius scale of 14 / 12 / 8 / 6 — a child box is never rounder than its parent.**
4. **Every widget that reads a colour token must call `AppTheme.watch(context)` itself.**

> Why rule 1 *works*: the contrast between surfaces is negligible
> (dark `panelBg` vs `cardBg` = **1.105:1**; light `panelBg` vs `surfaceFill` = **1.053:1**).
> A block that changes only its `color` without an `AppGlass.cardShadow` is **effectively invisible** —
> dropping the border *forces* a shadow to make up for it.

### Five token families

| Family | Used for | Example (light / dark) |
|---|---|---|
| `AppPalette` | Base colours | `windowBg` #FFFFFF / #0A0A0A · `panelBg` #F9F9F8 / #141414 · `cardBg` #F3F3F2 / #1E1E1E |
| `AppSurface` | Chrome overlay (mostly **translucent**) | `hoverFill`, `selectedFill`, `accentWash`, `recess`, `scrollThumb` |
| `AppGlass` | **Raised** surfaces | `surfaceFill` #FFFFFF / #202020 · `bubbleFill` · `rowFill` · `cardShadow` |
| `AppCard` | The card recipe | `base`, `inset`, `radius`=12, `insetRadius`=8, `heroShadow` |
| `AppControl` | Control sizes | `height`=32, `radius`=8, `menuRadius`=6, `fontSize`=13, `menuMaxHeight`=240 |

### The `AppTheme.watch` mechanism — why it's needed

The app is full of `const AppSidebar()`, `const _MainShellBody()`. A `const` child is reference-identical
across rebuilds of its parent → Flutter short-circuits, so **a rebuild from the root never reaches the
sidebar**. Second case: a `ListView.builder` item is kept across a list rebuild (`ChatBubble` once stuck the
whole transcript on the old palette).

The fix: `_BrightnessScope` + `_FontScope` are `InheritedNotifier`s — they mark dependents dirty
**directly**, through every `const` boundary. **There are currently ~540 `AppTheme.watch` call sites** in
`lib/` (measured 2026-08-12; `design-system.md` says 186 — long stale).

**Quick audit:** count token reads vs `AppTheme.watch` in a module — reads > 0 with watch == 0 is a certain
theme-flip bug.

### Traps pinned by comment

- **`windowBg` is the *page* background, not a raised surface.** Dark `#0A0A0A` is **darker** than panel
  `#141414` and card `#1E1E1E` → a dialog taking `windowBg` *sinks below* the page. In light this bug is
  **invisible**
- **Raise the parent block's background and you must lower the child field's.** `LabeledField` defaults to
  `cardBg` fill; on an already-raised dialog (`#202020` dark) that's only **1.023:1** → pass
  `fill: AppCard.inset` (1.09:1). In light it's the reverse → choose by brightness
- **Don't mix the two accent tokens.** `AppPalette.accent` `#2F5BEA` is **only** a fill under white text (on a
  dark ground it's just 2.6:1). Accent text/icons use `accentOnSurface` (`#6E8BFF` dark, 4.65:1)
- **`colorScheme.onError` is NOT set** → it falls to the Material default, only **3.83:1** on `error` dark.
  A coloured button → **measure the text on that ground**, don't trust the `on*` token
- **`AppGlass.rowFill` ≠ `surfaceFill`.** In light `windowBg` is `#FFFFFF` and so is `surfaceFill` → a row and
  the page are at **1.000:1**. You can't raise a block on a pure-white page → light **recesses**, dark
  **lifts**
- **`'SF Mono'` doesn't resolve in CoreText** — it returns nil, and Flutter silently falls to Menlo. It can
  only be reached via the internal name `.AppleSystemUIFontMonospaced`
- **A menu positions itself by summing its own row heights** — change the padding and forget the `_menuSize`
  constant and the menu drifts off the button

### Three verification laws (learned by bug)

1. **Compute colour and geometry; don't eyeball a screenshot.** Compression/scaling/colour-profile shifts
   kill thin details — three false alarms already. A token with alpha must be **composited** in the right
   layer order before computing WCAG. "Measuring" geometry means `tester.getRect()`, **not reading code and
   reasoning**
2. **For platform behaviour, LOOK AT THE REAL APP.** A headless test reports PASS on genuinely-broken
   font/focus/selection (the test font manager resolves every family to one test face). **Test vs image
   disagree → trust the image**
3. **Change any UI and check BOTH light and dark.** Light usually forgives, dark doesn't

### Three Material widgets **never** used raw

`Card()` (→ `AppGlass.surfaceFill` + `cardShadow` radius 14) · `DropdownButtonFormField` (→ `AppSelectField`)
· `MenuItemButton` (the app has no `menuButtonTheme` → hand-roll the menu row).

### Hover — two sides; whoever hovers holds the state

- **Row-hover** answers "reveal the button"; **button-hover** answers "the cursor is over the button"
- A parent's hover **does not** flow to a child. A button must catch its own hover
  (`MouseRegion`/`InkWell.onHover` + `setState`). A bare `IconButton` skips this
- A row already on a washed ground needs more than colour — a button needs **its own fill** (radius 7)

---

## 10. Completeness

| Feature | State | Evidence |
|---|---|---|
| Chat + agent (3 runtimes) | ✅ **Shipped** | Full, ~644-line controller + 4 modules, resume/queue/goal/plan |
| **Panels around chat** | ✅ **Shipped** | 3 hosts × 3 features, tab strip, drag seam, expanded; geometry is pure — but `resolveSidePanel` **has no test** (§13) |
| **Review** | ✅ **Shipped** | 6 scopes, stage/commit/push, line comments, AI commit message, split/unified |
| **Terminal** | ✅ **Shipped** | real pty, 10k scrollback, attachable to a message |
| **Files** | ✅ **Shipped** | tree + breadcrumb + viewer, 2-mode Markdown, "Add to chat" |
| **Git (install/adopt)** | ✅ Shipped | Background install + Settings ▸ Coding ▸ Git |
| **Code half (shared repos)** | 🔒 **devOnly** | ProjectFlow catch-up/publish, task transcript, PanelHost.code — relay has no projects plane in prod |
| **Sync & Backup** | ✅ Shipped | Encrypted upload/download + merge; §7.27 |
| **Feedback** | ✅ Shipped | Dialog + optional log bundle + FeedbackOutbox; §7.28 |
| Skills | ✅ Shipped | 3 bugs found (§7.4), "Draft with AI" hard-off (`_showAiDraft = false`) |
| Connectors (gateway + DCR) | ✅ Shipped | `rest_entry_fallback.dart` is scaffolding awaiting the gateway |
| Scheduled tasks | ✅ Shipped | Model pinned via Hermes's own Python (`TODO(BE)`) |
| Projects | ✅ Shipped | |
| Grid / network / members | ✅ Shipped | Member admin for a provider "BE support pending" |
| Provider node (local/external/API) | ✅ Shipped | Engine log dev build only |
| Models | ⚠️ **Partial** | 4 regressions from the split view replacing the old UI (§7.10) |
| Playground | ✅ Shipped | Responses path doesn't stream |
| Auto router | ✅ Shipped | |
| Appearance | ⚠️ Partial | Font picker **works only on macOS** |
| Messages | 🔒 **devOnly** | Full config writer; toolset pinning removed (a security risk, §7.7) |
| Plugins | 🔒 **devOnly** | Codex plane permanently null |
| Grids (tab) | 🔒 devOnly | |
| Debug | 🔒 devOnly | |
| Media / ComfyUI | ❌ **Flagged off** | `kMediaSetupEnabled = false` |
| Browse-connectors dialog | ❌ Flagged off | `kShowBrowseConnectors = false` |
| **Overlord** | ❌ **FAKE + UNREACHABLE** | `FakeOverlordRepository` hardcoded; 0 routes; 20 files, 1,417 lines dead |
| Composio | ❌ **Not one line of Dart** | `composio-proxy-contract.vi.md` says "the app has implemented this" — **wrong** |
| Windows auto-update | ❌ Deferred | `isSupported => Platform.isMacOS` |
| `GridResolver.configuredPath` | ❌ Not wired to UI | `providers.dart` builds a bare `GridResolver()` |
| Agent switcher (Skills/Connectors/Plugins) | ❌ Not built | `extensionAgentProvider` **always** returns `hermes` |
| Approval for Codex/Claude | ❌ **No channel** | `TODO(BE)` — both run full access |

---

## 11. The most important invariants

This list is things that **each was once a real bug**. Reversing one recreates the bug.

### Security / safety

1. **Secrets go only through the `environment` channel, never into argv.** The log records only the *name* of
   a variable; the `Authorization` header is never written
2. **`ConnectorBridge` authenticates nothing** — the only fence is the loopback-only bind
3. **Codex/Claude run full access, asking no one.** `ApprovalPicker` **governs only Hermes**
4. **The Telegram/Discord/Slack bot allowlist is a security boundary**, not a convenience — toolset pinning
   was removed
5. **A refresh-token failure NEVER deletes anything** — the `refresh_token` is the one thing that can still
   recover
6. **`ready` from `/poll` arrives only once** → write disk before anything else, confirm by **reading it back**

### Process lifecycle

7. **Need BOTH `onWindowClose` AND `didRequestAppExit`** — `setPreventClose` doesn't cover ⌘Q
8. **`grid leave` deliberately carries no `--engine`** in remote mode
9. **`resetAgentFeed()` must run synchronously, before any `await`**
10. **`slot.seen++` / `live.seen++` only on a successful turn**
11. **`StdioLineWriter` queues rather than writing straight through** — `IOSink.flush()` *binds* the sink; a
    write slipping in between throws and **loses that line** (once hung Hermes for nearly 6 minutes)
12. **Closing a panel tab must `endSession(tabId)`** — an orphaned pty is a process the user can no longer see
    to stop. Called from `PanelTabs.close()`, **not** a watcher (a watcher runs only while someone is looking)
13. **Kill a shell with `SIGHUP`** (Windows: `SIGTERM`) — `SIGTERM` leaves the shell's children holding a pty
    nobody reads
14. **`git` runs with `GIT_TERMINAL_PROMPT=0` + `ssh -o BatchMode=yes`** — the app has no terminal, so a
    prompt nobody can answer hangs until the timeout
15. **macOS: never exec `/usr/bin/git`** — it's an `xcode-select` stub, and running it **pops Apple's
    installer**; resolve via `xcode-select -p` and use an absolute path

### Data

16. **`archivedAt` uses `_parseNullableDate`**, not `_parseDate` (epoch fallback)
17. **`copyWith` can't unset via `?? this.x`** → needs a flag: `clearArchivedAt`, `clearGoal`,
    `clearUiFontFamily`, `clearCategory`, `clearOutgoing`…
18. **Everything that reads chat history uses `state.live`**, not `.conversations`
19. **`saveRefreshed` merges, doesn't assign**
20. **`null` ≠ `ConnectorTransport.none`**; **`advertises_*` is tri-state**, `null` ≠ `false`
21. **An empty `served` = "not loaded yet"**, not "the grid serves nothing"

### Riverpod / render

22. **`gridOverviewSnapshot` is the only door** — `.asData` zeroes the numbers per poll; watching both an
    `AsyncValue` and a family in one body → `setState() during build`
23. **Value equality on `GridOverview` is load-bearing**
24. **`routeFor` takes a `GridOverview?`, not an `AsyncValue`**
25. **`CommandLogNotifier._schedule` = `Future.microtask`** is mandatory, not an optimisation
26. **Every widget that reads a token must call `AppTheme.watch(context)`**

### Wire protocol

27. **`ChatSendStreaming.text` is the WHOLE text; `ChatDelta.text` is a fragment.** Hermes's message is a
    **delta**; Claude/Codex are **whole text**
28. **`--mcp-config` must come with `--strict-mcp-config`**; a broken write → `null` → drop **both**
29. **`codex exec resume` takes neither `--sandbox` nor `-C`**, but the `-c` overrides must ride **every** turn
30. **`Accept: application/json, text/event-stream`** — both required (Canva returns 406)
31. **SSE takes the LAST `data:`**, not the first
32. **`CliResult.sessionExpired` is a string-match on four English sentences** — a CLI wording change makes
    the app silently stop detecting it

---

## 12. Run, build, release

### Dev

```bash
export PATH="$HOME/WorkPlace/Flutter/flutter/bin:$PATH"
cd autonomous-grid-app && flutter pub get && flutter run -d macos
```

The CLI has to resolve first:

```bash
cd ../autonomous-grid && uv tool install -e . --force   # → ~/.local/bin/grid
```

> **Gotcha:** `uv tool install -e .` freezes the version metadata at install time, so after switching CLI
> branches `grid --version` still reports the old number until `uv tool install -e . --force --reinstall`.

> **The sidecar beats `$PATH`.** The packaged build always uses the `grid` inside `Grid.app` even if you just
> installed a new one. Use `GRID_BIN`, or re-inject with `scripts/bundle_grid_macos.sh`.

CocoaPods is required (`/opt/homebrew/bin/pod`); prepend `/opt/homebrew/bin` to PATH, set `LANG=en_US.UTF-8`.

### The gate before "done"

```bash
flutter analyze lib test        # target: 0 issues
flutter test test/<area>        # logic tests — do NOT write new widget tests
dart format .
```

Test suite today: **172 test files**, and **0** of them contain `testWidgets`/`pumpWidget`/`WidgetTester` —
`grep -rl 'testWidgets\|pumpWidget\|WidgetTester' test` is now genuinely empty (the last legacy widget-test
files are gone; §8 conventions forbids adding new ones). Re-measure `flutter analyze` and `flutter test`
before quoting numbers — this doc no longer carries a standing count, because it went stale in the source doc
more than once.

### Build & release

```bash
./scripts/bundle_grid_macos.sh     # build the app + inject the Nuitka onefile sidecar
./scripts/package_dmg_macos.sh     # ad-hoc DMG
DEV_ID="…" NOTARY_PROFILE=grid-notary ./scripts/notarize_macos.sh
```

Push a `v*` tag → `.github/workflows/release.yml` → a draft release with
`Grid-<ver>-macOS-Apple-Silicon.dmg` + `Grid-<ver>-macOS-Intel.dmg` (both signed + notarized).
The Windows job is commented out until code-signing exists.

**Not bundled at runtime:** `llama-server` (`grid engine install llama.cpp`), ComfyUI
(`grid media install`). Provider node targets **macOS Apple Silicon** and **Linux NVIDIA**; on Windows the
app is effectively consumer/playground only.

---

## 13. Technical debt

### Dependency-direction violations (§1 conventions: `presentation → logic → infrastructure`, not the reverse)

| From | To |
|---|---|
| `infrastructure/api/connector_gateway_client.dart` | `features/auth`, `features/agents`, `features/connectors` |
| `infrastructure/cli/hermes_cron_service.dart` | `features/agents/logic/agent_plugin.dart` |
| `shared/widgets/choice_row.dart`, `step_row.dart` | `features/provider_node/presentation/engine_block.dart` |
| `shared/widgets/modality_mark.dart` | `features/playground/logic/*` |
| `features/provider_node/presentation/add_engine_options.dart` | `features/models/presentation/*`, `features/node_setup/*` |
| `features/agents/logic/adapters/*_extensions.dart` | `features/skills/logic/skill_author.dart` |
| `features/overlord/**` | `features/network/presentation/detail_widgets.dart` (`copyToClipboard`) |

`EngineSurface`, `PlaygroundModality`, `copyToClipboard` ought to live in `shared/`.

> **Root cause of the `infrastructure/ → features/` edges: the connector and agent data models sit in the
> wrong layer.** `ConnectorToken`, `RestEntry`, `McpServer`, `AgentPlugin`, `CronRunError`,
> `hermesPathProvider` are all **pure infrastructure** types placed in `features/`.
> The fix = move the model files down to `infrastructure/` or `core/` — **without changing a line of logic**.

Valid exemptions, **now three**: `shared/layouts/widgets/section_view.dart` imports 15 views,
`features/chat/presentation/panel_feature_view.dart` imports the `presentation/` of review/files/terminal,
and `features/code/presentation/widgets/code_panel_feature_view.dart` does the same for the Code panel. All
are **mapping tables** — a mapping table is forced to name both sides. What keeps the exemption from spreading
is **confining it to one file each**: nothing else in `chat/` or `code/` knows those classes exist.

**The newer domains are cleaner than the rest of the repo:**

| Domain | Imports out |
|---|---|
| `terminal/`, `git/` | only `infrastructure/` + `shared/` — **0 cross-feature** |
| `review/` | `playground/logic/{chat_transport, one_shot_target}` (writing the commit message), `projects/logic/project.dart` |
| `files/` | `chat/logic/workspace_browser.dart` (3 places) |

The last two edges are **new debt of the same old kind**: `ChatTransport`/`resolveOneShotTarget` is "call the
model once" infrastructure (the skill generator uses it too), and `workspace_browser` is folder-browsing code
— **both belong in `shared/` or `infrastructure/`**, not in `playground/` and `chat/`. The fix = move the
file, not the logic.

### Feature ⇄ feature import cycles (Dart allows it, but each is a lost boundary)

| Pair | Evidence | Level |
|---|---|---|
| `chat` ⇄ `projects` | `chat_sessions_controller.dart` ↔ `projects_view.dart` | logic ⇄ logic |
| `chat` ⇄ `scheduled` | `task_delivery.dart` writes **straight into chat state** ↔ `chat_history_list.dart` | logic ⇄ logic |
| `agents` ⇄ `skills` | 3 `*_extensions.dart` → `skill_author.dart` ↔ several `skills/` files → agents | logic ⇄ logic |
| `auth` ⇄ `provider_node` | `auth_controller.dart` (calls `shutdownServing()` on logout) ↔ imports back | logic ⇄ logic |
| `auth` → `network/presentation` | `browser_fallback.dart` → `detail_widgets.dart` | **presentation cross-feature** |
| `chat` ⇄ `terminal` | `panel_tabs.dart` (now in `shared/panels/`) + `composer_context.dart` ↔ `terminal_session` doesn't import back | logic → logic, **one-way** |
| `chat` ← `files` | `files_filter.dart` + widgets → `chat/logic/workspace_browser.dart` | logic ⇄ logic |

The `chat` ⇄ `terminal` pair is **one-way** and deliberate: `terminal/` doesn't know what a panel is
(*"a terminal has no business knowing what a panel is"*), so `chat/` (via `shared/panels`) calls `endSession`
rather than the reverse. That's the right shape — only the last step is missing: moving `TerminalCapture` down
to `shared/`.

### Choke-point types — change one and many places break

| Type | Where | Fragility |
|---|---|---|
| `GridCliService` (3 methods) | `cli/grid_cli_service.dart:76` | many call sites, one build point. `sessionExpired` is a **4-English-sentence string-match** |
| `ChatSendUpdate` (sealed 5) | `playground/logic/chat_sender.dart:23` | the merge point of **all four** sending paths |
| `Conversation` | `chat/logic/conversation.dart` | 6 domains read it; `archivedAt` a timestamp; needs `clear*` flags |
| `NetworkCredential` | `state/models/network_credential.dart` | 3 different permission axes; `isPublic` **deliberately inverted** |
| `ConnectorToken` + `McpEntry` + `RestEntry` | `agents/logic/` | the one type that crosses **all three planes** |
| `AgentExtensions` (3 planes) | `agents/logic/agent_extensions.dart` | **a null plane is a valid answer**, not an error |

### Pure functions that call themselves "testable" but **have no test**

§8 conventions: *"pure logic (parsing, deriving, planning) lives in side-effect-free functions **and is unit
tested**"*. These functions have a doc comment justifying their purity **by testability** — and then nobody
wrote the test:

| Function | The doc comment says | Test |
|---|---|---|
| `resolveSidePanel` (`shared/panels/panel_metrics.dart`) | *"Pure, and out of `build` on purpose: these are clamps that have to agree"* | **0** |
| `decodeFilePreview` (`files/logic/file_preview.dart`) | *"Pure, so these three judgements are testable without a filesystem"* | **0** |
| `filePathCrumbs` (`files/logic/files_path.dart`) | — | **0** |

`resolveSidePanel` is the costliest of the three: it governs **every** pane size, and `kProjectMinWidth`'s own
comment recounts that a prior measurement **shipped stripes across the real composer**. Its neighbours
(`tabStripTabWidth`, `tabStripScrolls`) **do** have tests — so this gap is an omission, not a decision.

### Observability blind spots

**Only a handful of files** emit `CliCallKind.http` (the network controllers, `grid_overview_provider`,
`member_providers`, `network_models_provider`, `playground/chat_sender`, `skills/skill_generator`). So these
**don't** show in the Debug tab or `app_https-*.log`:

- all of `ConnectorGatewayClient` (the OAuth broker — only `appLogProvider`)
- `ModelCatalogClient` — **logged nowhere**
- `SmitheryRegistryClient`
- `FeedbackClient`
- `McpProxy` / `RestInvoker` — **the agent's real tool calls**
- all HTTP fired by `claude`/`codex`/`hermes` themselves

> When a user reports "the connector doesn't work" or "the agent's tool call failed", **the on-disk HTTP
> transcript holds nothing.** You debug via `appLog`.

### Current measurements (2026-08-12)

- `lib/`: **775 Dart files, ~140,300 lines, 29 feature domains**.
- **`TODO` in `lib/`: 31 total, of which 26 are `TODO(BE)`** (awaiting the backend).
- **`AppTheme.watch`: ~540 call sites.**
- Gateway connectors (measured earlier, re-measure before quoting): ~12 rows, mostly `auth_type: app`, many
  with a `mcp_url`, many returning `description: ""` (which is why `connector_blurb_fallback.dart` exists).

| | 06/08 | 10/08 | 12/08 |
|---|---|---|---|
| Dart files in `lib/` | 558 | 668 | **775** |
| Lines | ~105,000 | ~120,900 | **~140,300** |
| Feature domains | 23 | 26 | **29** |
| `AppTheme.watch` | 399 | 486 | **~540** |

> Re-measure before quoting any number here. This table has gone stale repeatedly.

### Measured dead code (re-checked 2026-08-12)

`overlord/**` (**20 files, 1,417 lines**, unreachable) · `models/presentation/{download_row,manager_search_field}.dart`
(0 imports; `suggested_models_section.dart` was deleted) · `catalogModelsProvider` (only its own definition
left) · `shared/layouts/widgets/{hosting_summary,plan_type_pill}.dart` (0 call sites, if still present) ·
`shared/widgets/{pulse.dart::PulseDot, coming_soon_view.dart, not_yet_badge.dart}` — the last two die **as a
pair**: `coming_soon_view` is the only call site of `NotYetBadge` · `conversation.dart::groupConversationsByRecency`
· `parsers/{member_entry,denylist_entry}.dart` · `api/models/chat_chunk.dart` · `run(timeout:)` (no call site
passes it) · `snackBarTheme` (SnackBar is banned, 0 call sites). (`model_shelf.dart::buildModelShelf` — named
in the prior list — no longer exists.)

⚠️ **`skill_generator.dart` changed status** — no longer "0 imports". `new_skill_dialog.dart` now calls
`skillGeneratorProvider`, but the **gate is a constant `final bool _showAiDraft = false`** at the bottom of
that same dialog file. So it *compiles into the bundle, has a call site, and is reachable by no path*. This
kind of dead code is harder to spot than the old kind: grepping "0 imports" **no longer catches it**.

### Design-system debt

| Violation | Count | vs earlier |
|---|---|---|
| Bare `IconButton` | (re-measure) | — |
| `backgroundColor: AppPalette.windowBg` (dialog sinks in dark) | (re-measure) | login_screen, project_instructions_dialog, create_project_dialog, agent_changes_bar, prompt_dialog, onboarding_page, home_shell |
| Bare `MenuItemButton` | (re-measure) | approval_picker, agent_picker, task_power_bar |
| Bare `CircularProgressIndicator` | (re-measure) | mostly in `models/`; the ones inside `AppSpinner` are valid |
| Bare `Card()` (Material) | (re-measure) | node_setup_card.dart |
| `DropdownButtonFormField` / `InputDecoration(labelText:)` / `SnackBar` | **0** ✅ | = |

> Re-measure these counts (`grep -rn 'IconButton(' lib` etc.) before quoting — they drift with new features.
> The notable earlier result was that thousands of new lines added **no** new violation to this table:
> `review/`, `files/`, `terminal/` build menus and spinners to the recipe.

#### Newer debt: the menu-row recipe is hand-copied **many** times

Design system §5 describes a "standard menu row", but `shared/` **provides no widget for it**. So each feature
that needs a menu rebuilds it — `chat_header.dart:_ChatMenuItem` (the reference, measured by test),
`panel_feature_menu.dart` (now in `shared/panels/`), `project_menu.dart:_ProjectMenuItem`,
`skill_menu.dart:SkillMenuItem`, `archived_chats_view.dart:_FilterMenuRow`, `review/presentation/widgets/menu_row.dart`
(with `MenuRowBody` + `MenuRowChevron`), and `files/presentation/widgets/files_menu_row.dart`.

They're all **correct** today, and each one's doc comment re-explains the same reason (Material is wrong on 4
points: radius 0, 14pt text, grey `onSurface` hover, a ripple). But that many copies of one recipe are that
many places for it to drift — and the rule "two screens asking the same question share the widget and the
words" (§5 conventions) is being violated in exactly the hardest-to-see place.

**Fix:** one `AppMenuRow` in `shared/widgets/`, built from `_ChatMenuItem`. `review/menu_row.dart` is already
the fullest (it has a chevron for submenus), so it's the best candidate to lift.

Also, **inside `shared/` itself**:
- `appMenuStyle()` hardcodes radius **10** while `AppControl.menuRadius = 6` → three menu kinds mismatch 6/6/10
- Two parallel menu fill colours: the theme sets `#1E1E1E`, `appMenuFill()` returns `#2A2A2A`. A `MenuAnchor`
  that **doesn't** pass `appMenuStyle()` gets `#1E1E1E` — only 1.023:1 against `surfaceFill`, a panel **with
  no edge**
- `AppMotion` isn't respected: ~8 places hardcode a duration
- `LogView` hardcodes `#1E1E1E`/`#D4D4D4`, not theme-aware

### Stale documentation

| File | Wrong where |
|---|---|
| `README.md` | Says Provider/Models gate by role — they gate by `devOnly × build mode`. Points at 3 `docs/` files that **don't exist** |
| `docs/OVERVIEW.md` | Written 14/7 — missing many domains; its §8.10 describes a skill API that was deleted |
| `docs/messages-tab.md` §5 | Describes `_restrict()` pinning toolsets — the code does the **opposite** (unpin) |
| `docs/features/connectors/composio-proxy-contract.vi.md` | Says "the app has implemented this and is waiting" — **0 lines of Dart mention Composio** |
| `docs/features/connectors/gateway-api-for-grid-desktop.md` | Describes a contract quite unlike the one running (D12 supersedes D9) |
| `docs/design-system.md` | Records 186 `AppTheme.watch` call sites (actually ~540); files `surfaceFill`/`sidebarFill` under `AppSurface` (actually `AppGlass`); §4 says `w600` (actually `w500`). **Says nothing about panels** — `PanelBody`, `PanelSplitter`, `PanelToggle`, the toolbar height and the 96–180px tab scale are all standard geometry now, absent from the spec |

### `TODO(BE)` — awaiting the backend

- The relay **doesn't advertise the context window** (`context_length: null`) → the app must *learn* it from
  engine errors
- The gateway hasn't shipped `rest_entry` → `rest_entry_fallback.dart` is scaffolding to be deleted
- The gateway hasn't shipped `description` → `connector_blurb_fallback.dart` (stand-in descriptions)
- The grid-rename endpoint **validates nothing** (unlike create)
- `hermes cron create/edit` lacks `--model`/`--provider`/`--toolsets`
- `agent_release_pins.dart` is a **hand copy** of the CLI's Python installer — the CLI bumping a version and
  forgetting to bump here ⇒ a hash mismatch ⇒ **every** install fails. Proposal: `grid agent spec --json`
- `kHermesAcpRequirement = 'hermes-agent[acp,mcp]'` but the CLI's installer still only asks for `[acp]` →
  `grid agent install` from a terminal builds an env **with no MCP SDK**, and every connector dies silently
- Per-action approval for Codex and Claude Code
- **The Code half's "publish on completion" watch is client-side** (§7.29) — the durable place for it is the
  relay

---

## Related documents

- [`docs/design-system.md`](design-system.md) — **the canonical spec** for the UI, read before styling anything
- [`docs/conventions.md`](conventions.md) — architecture, Riverpod rules, Dart style, copy rules, testing policy
- [`docs/style-guide-grid-app.md`](style-guide-grid-app.md)
- [`docs/git-auto-install.md`](git-auto-install.md) — Git probe/download/adopt detail (§4.6, §7.25)
- [`docs/messages-tab.md`](messages-tab.md) — ⚠️ §5 is stale
- [`docs/OVERVIEW.md`](OVERVIEW.md) — 14/7 handover, still right on build/release
- [`scripts/README.md`](../scripts/README.md) — sidecar bundling, signing, packaging
