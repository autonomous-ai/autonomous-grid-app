# Grid Desktop App — Architecture, Domain & Features

> Full architecture note, built by reading all of `lib/` (**845 Dart files, ~160,200 lines, 29 feature domains**).
> Updated: **2026-08-18** · branch **`main`** · version `0.2.0+1`
>
> **The panel work is on `main` now.** The `device` branch this note was last written from has been merged,
> so the **Grid Panel** — a physical companion device (an ESP32 board with a 480×480 screen) on the end of a
> USB cable, which the app answers, mirrors live turns to, takes voice from, and reflashes — is simply part
> of the tree. §2 (the fifth plane), §4.7 (the wire), §7.30 (the domain), and the normative
> [`docs/panel-protocol.md`](panel-protocol.md). The device half is here as `device/esp32-circle/`
> (**65 tracked files**); the older `esp32-square` firmware was deleted on 2026-08-17.
>
> ⚠️ **Two unrelated things are called "panel" here.** `lib/shared/panels/` + `PanelHost`/`PanelFeature`
> are the **work panels around a conversation** (Review / Terminal / Files, §3, §7.22–§7.24).
> `lib/features/panel/` + `lib/infrastructure/panel/` are the **hardware Grid Panel** (§7.30). Same word,
> unrelated code.
>
> **The runtime count went back down: there are three.** The prior version of this note corrected "three"
> to **four** (Hermes, Codex, Claude Code, **Pi**). Pi was removed on 2026-08-18 — every `pi_*` file, the
> adapter, the installer and the sealed event family — so it is **Hermes, Codex, Claude Code**, plus the
> **Auto** meta-choice, which is now **developer-only** (`autoAgentIsOffered`). §4.3, §7.2.
>
> The 08/17 measurement read **821 files / ~154,300 lines / 30 domains** (on `device`); 08/12 read
> **775 / ~140,300 / 29**; 08/10 **668 / ~120,900 / 26**. The domain count *fell* by one while the panel
> arrived, because **`prompts/` was deleted whole** — the `/` menu it owned now runs commands the app
> performs itself. The ~6,000 new lines are three themes:
>
> - **The slash menu became commands** (`chat/logic/commands/`, §7.1): `/clear`, `/compact`, `/goal`,
>   `/loop`. Each does something no message could ask an agent to do, on state the app owns — which is the
>   only kind of command that can work across three agents Grid does not speak the internals of.
> - **Every agent can now ask permission.** Claude Code over `--permission-prompt-tool` + a stdin
>   `stream-json` channel, Codex over `codex app-server`'s JSON-RPC — replacing `bypassPermissions` and
>   `codex exec`. One decision function (`decideAgentPermission`) means the mode picked in the composer
>   says the same thing whichever agent answers (§4.3, §7.2).
> - **A chat is written off the UI isolate** (`ChatStore`, §7.1). Measured on a 9 MB conversation a `/loop`
>   had worked in overnight, saving cost **98 ms to encode + 28 ms to write, on the UI thread**, and a loop
>   iteration commits three or four times.

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
| **AI assistant** | Chat with a locally running agent (Hermes / Codex / Claude Code, or **Auto** — developer builds — to let the grid pick one per question) — the agent reads/writes files, runs commands, browses the web, drives a real browser, holds a long session |
| **Bringing history with you** | Import the conversations Claude Code and Codex already have on this computer, and **carry them on** — the same session id, resumed from here (§7.1) |
| **Extending the agent** | Install **skills** (folders of instructions), **plugins** (tool backends), **connectors** (OAuth into Gmail/Slack/Notion/… over MCP) |
| **Automation** | **Scheduled tasks** on a cron; results drop into the Chat tab; `/goal` lets one chat run itself until a second model says the condition holds, `/loop` re-runs a prompt on a timer (§7.1); **Messages** lets you reach this machine over Telegram/Discord/Slack |
| **Grid (network)** | Create / join a grid, manage members, see how strong the grid is (VRAM, nodes, tok/s), auto-router picking a model |
| **Contributing a machine** | Run a provider node: local `llama.cpp`, an external server (Ollama/LM Studio), or an API engine (OpenAI key / Claude Code seat / Codex CLI seat) |
| **Models** | Browse a catalog suggested for your hardware, download GGUF, serve it, set context length |
| **Playground** | Chat / image generation / video generation over an OpenAI-compatible stream straight from the relay; the composer also takes **voice** (`grid stt transcribe`) |
| **Projects (Home)** | A project = a folder the assistant may read, plus rules + memory joined onto the opening turn |
| **Working beside the chat** | Two **panels** around the conversation, each with several tabs: **Review** (a project's diff, stage/commit/push, per-line comments), **Terminal** (a real shell over a pty), **Files** (browse & read project files). Their contents flow back into the composer: attach a terminal, attach a file, attach a highlighted snippet |
| **Code (shared repos)** | A second half of the app: shared repositories a grid hosts, read as conversations, where you post a coding task and a teammate's machine runs an agent on it (§7.29) |
| **Off the screen** | A **Grid Panel** on the desk — a small screen on a USB cable showing what each project is doing, and taking a spoken instruction without touching the window (§7.30) |

### The essence

> **The app is a GUI shell around the `grid` CLI (Python) plus a driver for three external agent
> runtimes.** The CLI owns the grid's lifecycle; `~/.grid` is the source of truth. The app keeps **no**
> state of its own — run the CLI from a terminal and the app redraws itself.

The one qualification on "keeps no state of its own" is `~/.grid/app/` (§5): the chats, the projects, and now
the **resume points and import ledger** that let a conversation survive a quit. The CLI never touches that
folder, and nothing in it is authoritative about the *grid* — it is the app's memory of its own screens.

The biggest gap with the README (and with every handover note before this one): they describe **two** planes
— control = subprocess `grid`, data = HTTP relay. In reality there are **five**: the third, the **agent
runtime**, is larger than the first two combined; the fourth is **local tooling** (`git` + a pty); and the
fifth is **the device** on the end of a USB cable.

---

## 2. Overall architecture — the planes

```
┌────────────────────── Grid Desktop App (Flutter + Riverpod) ───────────────────────┐
│                                                                                     │
│  ┌── CONTROL PLANE ───────┐  ┌── DATA PLANE ────────┐  ┌── AGENT PLANE ──────────┐ │
│  │ GridCliService         │  │ RelayApiClient       │  │ ClaudeExecService       │ │
│  │  (3 methods: run/      │  │  models/overview/    │  │ CodexAppServerService   │ │
│  │   start/pull)          │  │  usage               │  │ HermesAcpService        │ │
│  │ subprocess `grid …`    │  │ ConnectorGateway…    │  │ subprocess + stdio      │ │
│  │ auth · network ·       │  │ ManagedNetworkClient │  │ stream-json (both ways) │ │
│  │ provider · models ·    │  │ ModelCatalogClient   │  │ app-server JSON-RPC /   │ │
│  │ router · projects ·    │  │ SmitheryRegistry…    │  │ ACP JSON-RPC            │ │
│  │ stt                    │  │ HTTP + SSE           │  │ all three can ask       │ │
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
   │ app/* (app-owned) · connectors/  │        │ ~/.claude/projects · ~/.codex/sessions  │
   │ skills/ · bin/ · tools/          │        │ (the app READS here — never writes §7.1)│
   └──────────────────────────────────┘        └─────────────────────────────────────────┘
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

5. **An agent's *transcripts* are read-only, always.** `~/.claude/projects/**` and `~/.codex/sessions/**`
   are another tool's live state, and the import path (§7.1) only ever `openRead`s them. The one thing
   worse than failing to import a chat is corrupting the file the other tool resumes from.
   The one exception is a **repair** the app owns end to end: `~/.hermes/auth.json`, where a pooled
   credential minted for a grid the app is no longer pointing at is pruned (`HermesAuthStore`, §7.2) —
   `.bak` first, best-effort, and never touching a provider the user set up themselves.

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

### The fifth plane — **the device** (08/2026, on `main` since 08/18)

A **Grid Panel** on the end of a USB cable is neither a subprocess nor an HTTP peer: it is a serial link
the app opens for its whole life (`PanelScope`, above the router — §6) and **answers**.

> **Answering is all it does.** The panel runs nothing — no model, no agent, no file — so every message
> it sends is a question about state this app already keeps, and the answer is read back out of **the
> same providers the window renders**. A second reader of `~/.grid` would give two truths that disagree,
> and *"the panel says one thing and the window another"* is a miserable bug to chase.

```
lib/infrastructure/panel/   panel_frame (framing) · panel_message (JSON vocabulary)
                            panel_link (transport-agnostic) · panel_port (the real cable)
                            panel_firmware (+ provider) · panel_audio       ← all Flutter-free
lib/features/panel/         panel_controller (answers) · panel_turn_mirror (pushes live turns)
                            panel_voice (capture → grid stt) · panel_firmware_updater
lib/app/panel_scope.dart    opens the link after the first frame, above the router
```

Detail in §4.7 and §7.30.

### Code layering

```
lib/
├── main.dart              # boot sequence — the order is a contract
├── app/                   # MaterialApp, RootView (5-way router), single-instance, window lifecycle,
│                          # PanelScope (the USB device link)
├── core/                  # pure helpers: GridPaths, AppEnvironment, host_arch, composer_text
├── infrastructure/        # the backbone — NO business logic
│   ├── cli/               # GridCliService + 3 agent runtimes + Chrome bridge + git seam + parsers
│   ├── api/               # HTTP clients + DTOs (+ stt_client, the `grid stt transcribe` seam)
│   ├── mcp/               # ConnectorBridge, McpProxy, RestInvoker
│   ├── panel/             # the Grid Panel wire: framing, messages, port, firmware  (Flutter-free)
│   ├── state/             # stores that read/write ~/.grid
│   ├── platform/          # clipboard, notification, PDF, font, window focus, mic_recorder
│   └── logging/           # 4 disk sinks writing ~/.grid/logs + ErrorBurstFilter
├── features/              # 29 domains, each with logic/ + presentation/
└── shared/                # theme (design system), widgets, layouts (shell/sidebar/settings),
                           # panels/ (the WORK panels around a conversation — not the device),
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

`ShellSection` (`shell_state.dart`) has **17 values**. `section_view.dart` is the **single mapping
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
| `importChats` | `ImportSessionsView` | Settings ▸ Personal ("Import chats") | |
| `archived` | `ArchivedChatsView` | Settings ▸ Archived | |
| `messages` | `MessagesView` | Settings ▸ Integrations | ✅ |
| `grids` | `NetworksPane` | Settings ▸ Developer | ✅ |
| `debug` | `DebugView` | Settings ▸ Developer | ✅ |

> **`importChats` sits beside Sync & Backup, and the grouping is the argument.** Both move *this user's own
> chat history*: Sync carries it between their machines, Import brings it in from the tools they used before
> this app existed. Its icon is the arrow-into-a-tray, deliberately **not** a cloud — nothing is downloaded,
> the chats are already on this computer.

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
`OnboardingChoiceScreen`, `WelcomeScreen` (5 full-screen screens `RootView` chooses between — §6).

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
| `grid --remote stt transcribe <wav> --lang <en\|vi>` | `stt_client.dart` (§7.11) | stdout **is** the transcript; 35s timeout, a little past the CLI's own 30s so the CLI's message wins the race |
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
| `RelayApiClient` | `{lanSignalingUrl}/relay/v1` | `GET /models`, `GET /grid/overview`, **`GET /usage?since=&until=`** (unix seconds) |
| Chat/media (playground) | as above | `POST /chat/completions`, `/responses`, `/media/image/generate`, `/media/image/edit`, `/media/video/i2v` |
| `ManagedNetworkClient` | `api-grid.autonomous.ai` | `POST/GET/DELETE /v1/grid/managed-networks[/{id}/members]`, `PATCH /v1/grid/networks/{id}` |
| `ConnectorGatewayClient` | as above | `GET /v1/grid/connectors`, `POST …/start`, `/poll`, `/refresh`, `/disconnect` |
| `ModelCatalogClient` | as above | `POST /v1/grid/catalog` (suggest + list), `GET /v1/grid/catalog/{repo_id}` |
| `SmitheryRegistryClient` | `api.smithery.ai` | `GET /servers?q=… is:remote` — **sends no credential** |
| `FeedbackClient` | as above | `POST /v1/feedback` (§7.28) |

> **`GET /usage` is the only way to learn what an `auto` turn actually ran on.** The agent CLI makes the
> relay calls, so the app never sees their responses, and the agent only knows the name it was *given*
> (`auto`, or a tier alias) — never the one the router picked. Two consequences the code is explicit about:
> a grid whose master predates the endpoint answers **404**, which must read as *"no data yet"* and never as
> an error the user sees; and correlation is **by time window**, because a transaction carries no chat id —
> so two turns running at once on the same grid blend into each other's numbers. Accepted, not solved: the
> alternative is correlation plumbing across three repos for a caption (§7.1).

- `relayBaseUrl` is derived **at the client**: `'$lanSignalingUrl/relay/v1'`, `relayApiKey = accessToken`.
- **A relay URL names its grid in the *path*, never the host** (`…/<grid-id>/relay/v1`), and the token's JWT
  `aud` carries the same id. `core/relay_identity.dart` reads both and refuses to write a key next to the
  wrong endpoint — the mismatch the relay answers with
  `401 {"detail":"Invalid Grid token: Audience doesn't match"}`, *inside the assistant's turn*, where the
  user reads it as the assistant failing. The check is signature-blind and **fails open**: it exists to stop
  a *known* mismatch reaching disk, not to authorise anything.
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
| Command | `hermes acp` (1 arg) | `codex app-server` (JSON-RPC, one server per turn) | `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose …` |
| Protocol | **ACP JSON-RPC over stdio**, long session | **JSON-RPC over stdio**, 1 server/turn | `stream-json` JSONL **both ways**, 1 process/turn |
| Model routed by | `~/.hermes/config.yaml` (ACP has no model flag) | several `-c model_providers.grid-app.*` overrides | env `ANTHROPIC_BASE_URL` + `ANTHROPIC_*` |
| API key | config.yaml + `.env` | env `GRID_APP_API_KEY` | env `ANTHROPIC_AUTH_TOKEN`/`API_KEY` |
| Approval | ✅ ACP `session/request_permission` | ✅ `item/*/requestApproval` over the app-server | ✅ `--permission-mode default` + `--permission-prompt-tool stdio`, answered on the stdin control channel |
| Message event | **delta** (accumulated) | **whole text** (replaces) | **whole text** (replaces) |
| MCP | `mcp_servers:` in config.yaml | `~/.codex/config.toml` | `--mcp-config <file> --strict-mcp-config` |
| Resume | session lives in the process | the thread id, over the app-server | `--resume <sessionId>` |
| Survives a quit | ❌ the session **is** the process | ✅ written down (`AgentResumePoint`) | ✅ written down |
| Unique | cron, gateway messaging, plugins | — | browser lane (extension / CDP) |

> **Pi was removed on 2026-08-18** — `pi_tool`, `pi_chat_sender`, `pi_extensions`, `pi_exec_service` and its
> sealed event family are all gone from the tree, and `AgentTool` has three values. Anything still saying
> "four" is older than this line.

**Auto** is a fourth *choice*, not a fourth runtime: `kAutoAgentId = 'auto'` stored where an `AgentTool.id`
normally sits, and each turn asks the grid's auto model which of the installed three fits the question
(`auto_agent.dart`, prompt pinned by test) — mirroring how `kAutoModelId` names the model router without
being a model. It is **developer-only** (`autoAgentIsOffered => AppEnvironment.isDeveloperMode`): a router
that picks the wrong agent costs a whole turn, and that is not a first-time user's problem to debug.

#### Every agent asks now — one decision, three channels

This is the newest change in the plane and it reverses what this note said for weeks. `claude -p` and
`codex exec` looked non-interactive, so the app ran them wide open (`bypassPermissions`,
`sandbox_mode="danger-full-access"`) and the `ApprovalPicker` in the composer governed Hermes alone.
**Both have a channel; measured 2026-08-18:**

```
Hermes       ACP session/request_permission (inside its long-lived session)
Codex        codex app-server → JSON-RPC item/*/requestApproval
Claude Code  --permission-mode default --permission-prompt-tool stdio --input-format stream-json
             (control_request / can_use_tool — text-mode stdin is one-way, which is why
              the input format had to change too; `default` is the mode that ASKS, and
              `bypassPermissions` is the one that made the prompt tool a silent no)
                          │
                          ▼
             decideAgentPermission(ref, agent, chat, request, approval, answer, grantKey)
               readOnly / plan → refuse · ask → AgentPermissionCard · full → allow_once
               a grant the chat already holds (agentSessionGrantsProvider) → allow, logged
```

`decideAgentPermission` (`agents/logic/agent_permission_decision.dart`) is **one function for all three**,
sitting on top of the same `decideHermesPermission` policy: the mode the user picked in the composer has to
mean the same thing whichever agent is answering, and the way to guarantee that is to have one place decide.
`grantKey` exists because the transports remember differently — Codex holds its own `acceptForSession` for
the life of a thread, Claude Code remembers nothing, so "Allow in this chat" is kept **by the app** for it.

> ⚠️ **There is no type called `AgentEvent`.** `infrastructure/cli/agent_event.dart` is only a **shared
> vocabulary** (`AgentActivity`, `AgentPlanEntry`, `AgentPermission`, `AgentApprovalMode`,
> `AgentDetailMode`, `WebSource`, `TurnPart`). The runtimes keep **three fully separate sealed families**:
> `HermesAcpEvent` (`hermes_acp_service.dart`), `CodexEvent` (`codex_agent_service.dart`, parsed by
> `codex_app_server_parser.dart`), `ClaudeExecEvent` (`claude_exec_event.dart`). They meet only at
> **`ChatSendUpdate`**.
>
> Practical consequence: adding one new concept to every agent = editing 3 sealed families + 3 senders +
> 3 parsers, with **no compile error** to remind you if you forget one. Semantic differences already exist
> that **no type records**: message is delta vs whole text; only Hermes has a long-lived session. Permission
> used to be on that list — it is the one that got fixed, and it took a transport change on two of the three.

**The real convergence point** is `ChatSendUpdate` (sealed, **5 branches** —
`ChatSendGenerating`, `ChatSendStreaming`, `ChatSendAgentSession`, `ChatSendSuccess`, `ChatSendFailure`;
`playground/logic/chat_sender.dart`) — **all four sending paths** (relay + 3 agents) drain into it.
`ChatSender` is a **1-method, 12-parameter** interface, but **at least one impl deliberately ignores 6 of
the 12** (`workdir`/`instructions`/`planFirst`/`approval`/`conversationId`/`resume` with relay) — the
interface is **wider than the real contract**.

#### A turn is an ordered timeline, not an answer with steps attached

`TurnPart` (`infrastructure/cli/agent_turn_part.dart`) is sealed with two branches — `TurnText` (one
unbroken passage of prose) and `TurnStep` (one `AgentActivity`) — held in **one list, in the order it
happened**. Two lists could only ever draw the whole answer and then every step underneath it, which reads
as an agent that wrote first and worked afterwards: the reverse of what happened.

- **A step is what closes a passage.** `AgentRuns.upsertStep(chat, activity, answer:)` takes the answer as
  it stands, and only a **new** step divides it (`unsaidTail(said:, answer:)`); a *result* landing on a row
  already there changes its status where it sits, because nothing was said in between.
- **Every agent reports its answer cumulatively**, so the passage after the last step is the *remainder* —
  and `unsaidTail` deliberately falls back to "the tail alone" when the answer doesn't continue what was
  said, which is what Claude Code's closing `result` line does (it reports the final passage, not the turn).
  The prefix match ignores trailing whitespace: a passage is closed with the text exactly as it streamed,
  while the same answer reaches the landing **trimmed**, and comparing them literally showed one sentence
  twice.
- **`AgentActivityStatus` gained `unknown`.** A turn can end before a step reports (Stop pressed mid-tool, a
  process dies, Hermes doesn't always send the closing update). `settledParts()` on the way out and
  `_statusByName` on the way back in both refuse to keep `running`: a tick would vouch for a step that may
  have been killed, a red mark would accuse one that very likely worked. Saved as `running`, it reloads as a
  spinner turning forever inside last week's transcript.
- **Two payload caps, for two different questions.** `kToolPayloadLimit = 4000` is what a live fold shows;
  `kStoredResultLimit = 800` is what the *result* keeps on disk, because `chats/<id>.json` is rewritten
  whole on every turn and a twenty-command turn at the live cap is half a megabyte re-encoded per turn. The
  **request** is not cut to 800 — a command line is small and it is the half worth having later ("what did
  it actually run?") — but it *is* capped, since one tool's arguments carry a whole file body.
- Both cuts refuse to split a surrogate pair: a payload can be anything, emoji included, and a lone high
  surrogate survives `jsonEncode` and comes back as a replacement glyph.

**Session bookkeeping:** `AgentSessionSlots` keyed by `networkId|model|conversationId|workdir`, LRU 5.
Hermes **doesn't** use it (a slot holds a live process, and eviction must `close()`) — `HermesChatSender`
has its own LRU.

**`AgentResumePoint` is the same knowledge, written down.** `{agent, sessionId, seen, workdir}` saved beside
the conversation, so quitting the app no longer costs a chat its session and replays the whole transcript
into a fresh one. `planTurn(adopt:)` takes it **only when there is no live slot at all** — a slot whose key
no longer matches means the user changed something the session can't follow, and reaching past it to an
older id would resume the very session that mismatch retired — and only when `adopt.seen < history.length`.
Each sender re-checks `resume.matches(thisAgent:, thisWorkdir:)` before using it:

> ⚠️ **`claude --resume` and Codex's `thread/resume` take any id they are handed.** A foreign id fails loudly; the
> *right* id in the wrong folder **succeeds**, and the agent carries on editing the files it remembers
> rather than the ones the turn is pointed at. Both halves of the match are load-bearing.

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

### 4.7. Device link — the Grid Panel over USB

`lib/infrastructure/panel/` is **Flutter-free**, for the same reason `ConnectorBridge` is: the whole
protocol can be driven from `tool/panel_tap.dart` or a test with a pair of pipes and no cable. Four
layers, each ignorant of the one above:

```
panel_port.dart   the real cable   ─┐
                                    ├─ PanelTransport (an interface: bytes in, bytes out)
a pair of pipes in a test          ─┘
panel_frame.dart  framing          — A5 5A · version · type · u16 length · payload · CRC-16/CCITT-FALSE
panel_link.dart   messages         — typed PanelInbound; PCM kept OFF the message stream
panel_message.dart  vocabulary     — the JSON `t` discriminator, both directions
```

**Framing** (normative in [`docs/panel-protocol.md`](panel-protocol.md) §1): 8 bytes of overhead, payload
capped at **8192** — a bound on damage, not a capacity target. The reader **must resync**: the ESP32 ROM
and the bootloader both print to this port before the firmware owns it, so **every boot puts arbitrary
text in front of the first real frame**. On a bad length or a bad CRC it discards **one byte, not the
candidate frame** — the magic may have been a coincidence inside noise, and a real frame can begin one
byte further in. `discardedBytes` / `corruptFrames` / `unknownFrames` are counters because **the rate is
the diagnosis**: a handful at startup is the bootloader's parting words, a steady trickle is a format
disagreement or a bad cable. Frame bytes are **not** counted as discarded — that would make a healthy
link read as full of noise.

**An unrecognised frame type is not an error** — it is surfaced with its raw type byte, so a peer running
ahead reads as a version mismatch someone can act on rather than as a link that connects and then goes
quiet.

**Finding the port** (`panelPortIn`, pure and tested): the board enumerates **twice**, and only the native
USB-Serial-JTAG interface (`303a:1001`) carries this protocol — the other is a WCH CH343 console
(`1a86:55d3`) that opens, stays open and only ever delivers log text, which reads as a device that never
speaks rather than as the wrong port. So the match is **on the USB id and nothing else**, never by name or
by "the only one there". `ioreg` prints a *tree*, and the ids and the device path sit on different nodes
of it (`IOCalloutDevice` hangs two levels below, under the CDC driver), so the match arms a subtree by the
column `+-o` starts at and takes the first path inside it — a flat scan pairs a vendor id with whatever
path came next. The tty's line discipline must be put in **raw mode**; a mangled frame is
indistinguishable from a bad cable. The port coming and going (a flash, a crash, a nudged cable) is **the
normal case**, not the failure case.

**Firmware.** The app ships the image its own build was compiled against, so the two halves cannot drift:
`hello` reports what the panel runs, and anything else is offered a replacement over the cable it is
already talking on (frame type `0x03`). `esp32ImageVersion()` reads the version out of the ESP-IDF
`esp_app_desc_t` at byte 32 of the image — pure, which is why nothing else has to record it.

**The device half lives at `device/esp32-circle/`** (merged to `main` on 2026-08-18) — the Waveshare
board, ported from
`autonomous-code/apps/esp32-circle` **by deletion**: `ui_screens.c` went 7,243 → 4,546 lines and
everything else (`touch.c`, `display.c`, the fonts, the icons, `board/`, `audio_capture.c`) is
byte-identical, verified with `diff`. That is not tidiness — the previous port measured it: what was
copied behaved, what was hand-rewritten stuttered.

`.gitignore` keeps the build tree out: **412 MB on disk, 61 files tracked**, none from `build/`,
`managed_components/` or a generated `sdkconfig`.

> ⚠️ **`docs/panel-protocol.md` is still the only thing the two halves share.** No code crosses; the
> framing is written twice and agrees only because both sides assert against `test/vectors/panel_frame.txt`,
> which a **third** implementation (`scripts/gen_panel_vectors.py`) generates from the document. Some code
> comments still call the spec `docs/protocol.md` — same file, older name.

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
| `onboarding.json` | `{"decision": "local"\|"openai"\|"later"}` |
| `welcome.json` | `{"seen": true}` — the one-time welcome screen. **Its own file, not a field on `onboarding.json`**: that one records a *choice* and routes on it, this only records that a screen was seen |
| `imported_sessions.json` | The import ledger (§7.1): source agent + session id → the chat it became, its sha256, the file's size/mtime, and the importer's `formatVersion` |
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
| `~/.hermes/auth.json` | Hermes writes. The app **prunes** it (`HermesAuthStore`, `.bak` first): Hermes pools credentials by provider name and rotates on failure, so a pooled row minted for a grid the app no longer points at pairs an old key with the current endpoint → relay `401 Audience doesn't match`, inside the assistant's turn. Only rows whose `base_url` is *some other grid's* relay are touched |
| `~/.claude/projects/**`, `~/.codex/sessions/**`, `~/.codex/session_index.jsonl` | **Read only, never written** — the import path (§7.1) |
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
8. `runApp(ProviderScope(overrides, child: ConnectorRefreshScope › GridSkillsScope › PanelScope › NotificationScope › GridApp))`

> ⚠️ **Step 7 changed, and the reason was a real bug.** `ensurePermission()` **doesn't return until the
> user answers the OS dialog**. The window is built in step 5 but no frame is painted until `runApp` — so an
> `await` here left a **black, un-closeable window** the whole time the dialog stood there (on the first
> launch after each update). The notifier is now overridden **unconditionally** (`show` no-ops until it
> knows the answer), and asking is deferred to `HomeShell`, after the first frame.

The outermost scopes sit **outside the router** because connector tokens and skills belong to *the
agent* — the agent answers chats whether or not the user has the Connectors/Skills screen open.
`PanelScope` is there for a related reason and one of its own: **the device answers to the
desk, not to whichever screen happens to be open.** It draws nothing and does its work **after the first
frame** — finding the panel shells out to `ioreg`, which costs the better part of a second, and nobody is
waiting on a device that may not even be plugged in. The order inside it matters:
`panelControllerProvider.listen()` is wired **before** the port opens, because the panel introduces itself
the moment it sees the port and that handshake is a **broadcast** message — with no listener it is
dropped, not queued.

### `RootView` — the 6-way router

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
                 home      → welcomeSeenProvider ? HomeShell : WelcomeScreen
)
```

> **The welcome screen sits inside the `home` arm and nowhere else.** It is the last thing before the app,
> so it must not come between the user and a setup step they still have to finish. `markSeen()` writes
> `welcome.json` **before** flipping the state — the flip swaps this screen for the app, so a write after it
> would race a widget tree already being torn down.

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

`ChatSessionsController` (`chat_sessions_controller.dart`, **957 lines** — split by the jobs it does into
part files `chat_sessions_send` (849), `chat_sessions_state` (395), `chat_sessions_loops` (338),
`chat_sessions_goals` (243), `chat_sessions_queue`, `chat_sessions_settle` (144); **~3,000 lines across the
seven**) is the core, and the two newest parts are the two commands that run a chat by themselves (below).
State:

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

#### The `/` menu runs commands the app performs itself

`prompts/` — a library of reusable message bodies pasted into the composer — was **deleted whole** on
2026-08-17 and the slash it owned went to `ChatCommand` (`chat/logic/commands/`, pure: the catalog, the
parse, the menu's prefix match). The argument for the shape is the one thing worth keeping in mind:

> Grid drives **three agents over three transports**, and each agent's own `/commands` live inside the part
> of it Grid does not talk to (Codex's are in its TUI crate). So a command that works "for every agent" can
> only be one **the app performs itself, on state the app owns** — the transcript, the open chat, the turn
> loop. That is why the list is four long and will stay short. `parseChatCommand` claims **only** names in
> the enum, so an agent's own `/review` still goes out as the message it is.

| Command | What it does |
|---|---|
| `/clear` | A new chat **where the user is standing** — same project, or the chat list. Issue #13: it used to reach the assistant as text, which is exactly nothing. It also **ends the goal and the loop** on the chat being left, so neither goes on firing turns into a conversation the user has walked away from |
| `/compact` | Folds the history into a summary the next turn carries in its place (`ChatCompaction{summary, through, at}`, 90s, over the shared one-shot seam). Nothing is deleted — `historyForTurn` swaps `messages[0..through]` for the summary, and the transcript draws a divider at that point |
| `/goal <condition>` | Work toward a condition across turns. **No turn or minute ceiling** — a 30-minute default is what shipped issue #33, and Grid's own agent turns routinely run 40 minutes. It ends when a model reading the conversation says `MET`, or says `IMPOSSIBLE`; `kMaxGoalCondition` 4000 (it is re-read every turn), judge timeout 45s, and `kGoalStallTurns = 3` turns that did no work hands control back with the goal still set |
| `/loop [gap] <prompt>` | Re-run a prompt: on the user's gap, on one the assistant picks after each iteration (`kMinPacedDelay` 1m … `kMaxPacedDelay` 1h), or `continuous` (a `kContinuousLoopGap` of 3s, not a wait). Ceiling `kLoopExpiry` **7 days** |

Both of the two that run by themselves share the same four rules, each of which was a bug first:

- **A turn is stopped only when it has gone *silent*, not when it has run long.** `kLoopTurnStall` is
  **60 minutes of no progress at all** (`_turnActivityAt` stamps on every update), because a turn still
  streaming is doing the work the loop asked for. A wall-clock ceiling threw away real work.
- **A loop survives a restart.** The timers are in memory by nature, so a relaunch used to *end* a loop —
  and the only way on was `/loop` again, which is a **new** loop: count back to zero and the prompt sent
  again on top of what the killed turn had already done. `_resumeLoops()` re-arms at launch, checks the
  7-day ceiling first, waits `kLoopResumeSettle` (15s) before an overdue beat, and logs every resume.
  A loop arriving in a **restored backup** is stopped instead (`_stopForeignLoop`) — that machine holds the
  timer, and adopting the claim here would either double every turn or count down to a beat nobody arms.
- **A goal or a loop that was running when the app closed reads back as stalled/stopped**, never active:
  the recoverable answer is the one that doesn't start firing turns at a chat the moment it is opened.
- **Typed into a blank composer, they start the chat** rather than answering "Open a chat first"
  (`_startedChat`, 2026-08-18) — a chat isn't saved until its first message, but as far as anything on
  screen says the user is already in one. Everything that can refuse is checked **before** that, so a
  refused command leaves no empty chat in the sidebar.

**Where they are seen is two places, deliberately.** While either is running it is **one dim line under the
composer** (`ComposerStatus` → the shared `ComposerStatusLine`, which also carries services the agent left
running); once it ends, that is **news, and news goes into the transcript at the point it happened** —
`TranscriptEventRow`, anchored by `endedAfter`, the message count when it ended, stamped once. The stack of
three or four cards over the composer that this replaced sat there until somebody closed it, and said
"Goal met" above a conversation that had moved on.

#### Sub-features

| Feature | Mechanism |
|---|---|
| **Archive** | `archivedAt` is a **timestamp, not a bool**. `copyWith` needs a `clearArchivedAt` flag. `_commit` auto-unarchives when the user talks in the chat |
| **Pin** | `liveConversations()` pushes pinned to the front |
| **Goal** (`/goal`) | `ChatGoal{condition, status, turnsEvaluated, reason, endedAfter}` — **no turn or minute ceiling**. After every turn a second model reads the conversation and answers `MET` / `NOT_YET` / `IMPOSSIBLE`; not yet → the next turn goes out with the evaluator's reason as its brief |
| **Loop** (`/loop`) | `ChatLoop{prompt, interval?, continuous, iterations, nextAt, pacing, endedAfter}` — a prompt re-run on the user's gap, on one the assistant picks per iteration, or back-to-back. In-memory `Timer`s, **re-armed at launch** for a loop that outlived the app |
| **Plan mode** | approval = `plan` → a read-only turn + `withPlanPreamble` → `PlanApproveBar` → "Approve & run" sends the approving line with `planFirst: false` |
| **Queue follow-up** | Typing more while the agent runs → a queue with an X button; drained one at a time after the prior turn settles |
| **Attachment** | 3 entry points (+ button, ⌘V, drag-drop). Images cap 4, files cap 5, 25 MB. Text extraction: PDF via native (macOS only), docx/xlsx/pptx OOXML-parsed, truncated at 20,000 chars |
| **@-mention** | `activeMention(text, cursor)` — `@` must open a token; the menu reads `workdirEntriesProvider` (one level, cut at 60 rows) |
| **`/`-command** | The command menu (above); **mutually exclusive with `@`**, commands win |
| **Minimap** | A tick rail on the left, marking **user turns only**, shown only when content ≥ 1.5× the viewport |
| **Chat from a scheduled task** | id = `task-<jobId>`; `deliverFromAgent` creates the chat if absent and **doesn't** change `activeId` |
| **Voice into the composer** | The mic button drives `RecordingController` (§7.11) and feeds the transcript into the **input field**, never the transcript |
| **Vision lock** | An image attached to a chat whose text model has no `vision` → **Send is locked** until the user switches model or drops the image, rather than letting the relay reject it. A model missing from the options list counts as "can't be trusted to read images" |
| **Which models served the turn** | `TurnModelUsage` polls `GET /relay/v1/usage` every **5s** while a turn is open and takes one **last reading at the end** (a turn ending four seconds after the previous poll would otherwise lose its final requests). `ModelShare[]` is pinned onto the message and shown in its footer |

> **The model breakdown exists because naming one model was a lie.** A turn sent as `auto` is a routing
> instruction — the grid picks per request, and one agent turn is many requests. Even a *named* model fans
> out: Claude Code is handed a lead model, a small/fast one for side work and a subagent one, which on a
> grid serving tiers are three different models. Below `kPercentFloor = 10` requests the footer shows
> **counts, not percentages** — `67% · 33%` off three calls reads as a measurement when it is "two and one"
> — and percentages are apportioned by **largest remainder** so they sum to exactly 100.

#### Importing another tool's sessions (`chat/logic/import/`, 7 files + 3 screens)

Settings ▸ Personal ▸ **Import chats** reads what Claude Code and Codex already have on this computer and
turns each session into a real chat — one that can be **carried on**, because the id the other tool resumes
is the id this one resumes (`AgentResumePoint`, §4.3). Only those two: Hermes holds its conversation in a
live process, so there is nothing on disk to read and nothing to resume once it has exited.

```
SessionScanner.scan()          list only — name, folder, mtime, size. NEVER parses a transcript
  ~/.claude/projects/<slug>/<sessionId>.jsonl     cwd read from INSIDE the file (the slug is lossy)
  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl    + ~/.codex/session_index.jsonl for thread names
      ↓
SessionImportController         each row marked against the ledger:
      fresh · imported · changed · outdated
      ↓  import / syncAll(agent)
parseClaudeSession / parseCodexSession   pure, over a List<String> of lines → ParsedSession
      ↓
Conversation(+ resume: AgentResumePoint)  → ChatStore.save  → ledger.save → reloadFromDisk
```

- **Listing must not read transcripts.** Sessions on a real machine run to megabytes each (4.2 MB for one
  Claude session, 3.7 MB for one Codex rollout); a screen that parsed a hundred to draw a hundred rows would
  take seconds and hold the lot in memory to show a title. The head window is a generous **512 KB** and the
  reader **stops at the line that answers it** — breaking out of the `await for` cancels the read — so the
  ceiling is only ever paid by a file that never says. It is that large because a *line* can be enormous:
  one session opens with two 139-byte housekeeping lines and then a single **308 KB** user message, and
  through a 64 KB window it described itself as untitled, in no folder.
- **The ledger is what makes this a sync rather than a re-import.** `imported_sessions.json` keys on
  `agent|sessionId` — **not the path**, because Codex *moves* finished sessions into `archived_sessions/`
  and a moved session is the same session; the sha256 is computed once at import (never during a scan) and
  is what recognises it at its new path. It is read **against the chats that actually exist**, so deleting
  an imported chat offers the session again instead of leaving it un-importable.
- **`kImportFormatVersion` (currently 3) is why an unchanged file can still be `outdated`.** A record made
  by an older importer describes a chat built by rules this build has improved on — and the chat is already
  there, unchanged on disk, so nothing else would ever offer to rebuild it. Without it, the day tool steps
  stopped being a wall of quoted lines and became one monospace block, every chat imported before that day
  kept the wall forever.
- **Rows that can never be imported are dropped at the scan**, not left to fail at import: a session this
  app itself opened (recognised by `kProjectInstructionsHeader`, or by Codex's cwd being the app's own
  workspace) would import a duplicate of a chat already in the sidebar; a session opened and abandoned has
  no turn in it at all. A row that can't be imported is offered forever, counted in "Sync 5" forever, and
  fails every sync — three of those are why a finished sync still said there was work left.
- **One Codex *thread* is not one file.** Resuming or forking writes another rollout carrying the same
  `session_id`; listed per file that is three rows for one conversation, all importing to the same chat id,
  overwriting each other, with the ledger able to remember only one. The scan keeps the **newest file per
  thread** — the one Codex itself resumes.
- **A sync runs one session at a time, and a failure doesn't stop it.** The work is disk- and CPU-bound
  (230 ms for the biggest session here), so running them together would only hold every transcript in memory
  at once. `SyncOutcome` counts failures rather than returning a bool, because the screen has to be able to
  say "184 brought over, 3 couldn't be read" — announcing a flat success over a run that skipped three is
  the kind of dishonest copy §5 of the conventions calls a bug, not a wording problem.
- **Progress lives in a provider, not the screen.** Two hundred sessions take long enough that the user will
  click away, and a counter held in a widget would restart when they came back — or carry on invisibly with
  nothing saying the history was still growing. **Stop** is honoured *between* sessions: a half-written chat
  file is worse than one more chat.
- **Linking the folder as a project is opt-in**, and it is what makes the chat continuable: an agent resumes
  a session *in a folder*, and a chat belonging to no project runs in the app's own workspace — where the
  session would be resumed against files it has never seen. The resume point is written **either way**, so a
  folder added later makes the chat continuable then, without a re-import.
- **A title the tool chose is kept; a title this app derived is not preferred over the parser's.** Both
  tools park injected context at the head of the file, so a derived guess is often "The user opened the
  file …" — handing that to the parser as a preferred title overrode a perfectly good one built from the
  cleaned transcript.

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
- ~~`ChatStore.save` is a **synchronous write on the UI thread**~~ — **fixed 2026-08-18.** It queues the
  newest snapshot per chat and hands it to a spawned isolate, which does `toJson`, the encode and the
  write; `save()` returns in ~0 ms and the bytes land ~40 ms later. Measured on a 9 MB / 110-message chat
  a `/loop` had worked in overnight: encoding pretty-printed cost **98 ms** *per commit*, and a loop
  iteration commits three or four times. Two consequences to keep: writes are **compact**, not indented
  (0.7 MB off that chat and off every launch's decode), and **`loadAll()` awaits the writes in flight**
  (`ChatStore._inFlight` is `static` — the folder is the shared thing, not the object), which is what makes
  reading the folder from a second store safe
- ~~`chat_header.dart` `_menuSize` under-counts its own rows~~ — **fixed**: re-checked 2026-08-18, the
  constant computes **6 rows + 1 divider** and `_ChatMenuContent` builds exactly that. It feeds
  `anchoredMenuPosition` (§9), whose `maxHeight` clamp bounds only the *over*-estimate case, so the
  under-estimate this used to be was the one neither end corrects. The estimate is hand-summed, so it
  breaks again the day a row is added without touching the constant.

### 7.2. `agents/` — the agent abstraction layer (80 files, ~15,800 lines — the second largest)

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
| Permission | ACP request | `item/*/requestApproval` | `--permission-prompt-tool` + stdin |
| Unique | `hermes_grid_link`, `hermes_auth_store` (§5), `hermes_skill_scanner`, `hermes_shared_skills` | `codex_app_server_*` (transport + parser) | `claude_browser`, `claude_turn_mcp_config`, `claude_permission` |

#### Who answers a turn

```
ChatSessionsController.send()
  → chatAgentForProjectProvider(conversation.projectId)   ← fixed AT send, like approval
      chatAgentChoiceProvider = project.agent ?? chatPrefs.chatAgent
      'auto' → ask the grid's auto model which installed agent fits this question
               (auto_agent.dart: buildRouterMessages → parseRoutedAgent, degrade to a heuristic)
      resolve (NOT saved): pick it if _canAnswer (installed && agentRunsOnGrid)
                           else borrow the first agent that clears both bars
                           finally kChatAgent = hermes
  → agentAnswersTurn(modality, hasAttachments, agentInstalled)
      false → chatSenderProvider (relay HTTP)
      true  → agentChatSenderProvider(agent)   ← + conversation.resume (§4.3)
```

The user's pick is **never overwritten** → switching grids and back restores it. `agentSupportsModel` is the
one rule about pairings (Codex ✗ `claude:*`, Claude Code ✗ `codex*`, Hermes ✗ `codex:*`): the picker greys
the row rather than letting a turn fail on a model the harness can't speak to.

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

#### Approval flow — **all three have a channel** (2026-08-18)

```
a permission request, from whichever transport carries it (§4.3)
  → decideAgentPermission(...)      one function, all three agents
      a grant this chat already holds (agentSessionGrantsProvider) → allow, and log it
      → decideHermesPermission(toolKind, options, mode)      the policy, shared
          toolKind ∈ {read, search, fetch, think}  → allow at once, no prompt
          readOnly / plan                          → refuse
          ask                                      → ask the user
          full                                     → allow_once (NEVER allow_always)
  → AgentPermissionController.ask(), 55s timeout (Hermes gives up at 60s)
  → AgentPermissionCard pinned ABOVE the composer (not in the transcript, not scrolled away)
     — and, at the same time, a card on the Grid Panel if one is plugged in (§7.30)
```

> **This reverses what this note said for weeks, and the old state was the bug.** Codex and Claude Code ran
> `sandbox_mode="danger-full-access"` / `--permission-mode bypassPermissions` — writing files and running
> commands anywhere on the machine, asking no one — while the `ApprovalPicker` in the composer implied
> otherwise for all three. Both were moved onto transports that *can* ask: Codex to `codex app-server`,
> Claude Code to `--permission-prompt-tool` with a `stream-json` stdin. The picker now means what it says.
>
> ⚠️ Two things that follow, and neither is obvious: **the widest grant is never handed out** (`allow_always`
> would outlive the chat), and **"Allow in this chat" is remembered by the app for Claude Code** because
> that transport remembers nothing itself — `grantKey`, keyed by chat.

#### Five built-in `grid_*` skills

| Skill | Script | Does what |
|---|---|---|
| `grid-web` | `search.py`, `read.py`, `browse.py` | Search & read the web via `uv run --with ddgs/trafilatura/playwright`. **Codex and Claude Code on a grid have no web search** — their tools come from the vendor API |
| `grid-host` | — | "What's on this machine" — macOS has no `timeout`/`gh`/`rg`. Distilled from 83 recorded Codex turns |
| `grid-serve` | `serve.py` (~540 lines) | Run a service that outlives a tool call: launchd → screen → tmux → detached |
| `grid-research` | (uses `grid-web`'s scripts) | A research method: many queries, read real pages, a "Not verified" section |
| `grid-chart` | — | Teaches the agent the ```` ```chart ```` format the transcript renders. Without it the chart feature is **invisible** |

Installed at launch via `GridSkillsScope` for **all three agents**, written to **two** places (the library +
the agent's folder) and **rebuilt rather than copied** (the card embeds an absolute path to its own script).

> **This changed, and the old behaviour had shipped a bug that could not be fixed.** The installer used to
> write only when the folder **didn't exist**, so a build could not repair a skill already on a machine: for
> ten days `grid-serve`, `grid-host` and `grid-web` sat on disk with front-matter Codex rejects — dropping
> all three from the skill list it shows the model — and the fixed build reached nobody. It now **compares
> contents** and overwrites what differs. Comparing rather than rewriting is what preserves the reason for
> the old check: this runs on every launch and again before chats, and an unconditional write moved every
> card's "Last updated" (which the Skills screen sorts by), so a skill nobody had touched in a month read as
> changed a second ago. An unchanged skill is still not written.

#### Claude MCP handshake — the main quirk

`claude -p` loads **every** server in `~/.claude.json`, handshakes them in parallel, and closes the tool
list at some point. Measured 2026-08-04 with 27 servers: over 6 turns, `github` made the list 4 times,
`gmail` 3, `googledrive` **never**. Capping to Grid's 3 connectors ⇒ **4/4 connected, all 164 tools**.

- `--strict-mcp-config` is only half the work — without it the document is *merged* with `~/.claude.json`
- `--mcp-config <nonexistent path>` kills the turn **before the model** → a broken write must return `null`
  to drop **both** flags
- A chat turn passes **`withoutBundledSkills: true`**: Claude Code's own bundled skills include a ~922 KB
  reference for Anthropic's API, and a window this turn needs for the conversation is not the place for it.
  Grid's own skills live elsewhere and are untouched

#### Pointing Hermes at a grid — the memo has three parts, not two

`hermesConfiguredProvider` remembers what `~/.hermes` was last written for, so a message doesn't rewrite the
config every time. `pointingKey(network, model)` = `networkId | model | sha256(relayApiKey)[0..12]` — the
token is the third part, and it was the missing one: it rotates under the app (sign-out/in on the same grid,
the serve loop's refresh-on-401, `grid sync`), and a memo that knew only `networkId|model` left Hermes
answering with a key handed to it hours earlier until the app was restarted. The digest is change detection,
not a secret store.

Three things hang off that:

- `build()` **watches `sessionProvider`**, so any re-read of `credentials.toml` resets the memo — the next
  message re-points even when the token is unchanged, which is also what lets the repair passes re-run.
- A credential already **expired** is not written anywhere: `point()` calls `SessionExpiryController.onExpired()`
  and returns `kGridSignInStale` ("send again in a moment"), because renewal reuses the saved session and
  needs no browser in the common case.
- A relay **401** calls `forgetPointing()` → the next turn rewrites `~/.hermes` from `~/.grid` **and**
  re-runs `HermesAuthStore.pruneForeignGrids` (§5). That is what makes the failure self-repairing on a
  machine already in the broken state: nobody has to be talked through editing a hidden file.

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
hand, and projecting all of it into **the three agents that have an MCP plane** so one sign-in works
everywhere — which today is all three of them. The **null-plane rule** stays in `AgentExtensions` for the
same reason it was written: Codex has no plugin manager at all, so that plane is permanently `null`, and an
agent with no MCP would be `null` on both. A null plane is a valid answer, not an error.

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
> is the only gate left — it is a **security boundary**, not a convenience.

Also: tokens are plaintext in `.env`, and the **`.bak` keeps deleted tokens** (`EnvFile._write` copies the
`.bak` before **every** write, including `removeEnv`'s).

### 7.8. `network/` — the P2P grid

**Owns:** create/rename/delete a grid over the control plane, membership, reading live state from the relay,
inferring "how strong is this grid", and all of "How to use".

#### Three permission axes — often confused

| | Meaning | Gates |
|---|---|---|
| `role == admin` (`isOwner`) | Grid owner | Delete, Rename, **removing a member**, AutoRouterCard |
| `isProvider` = `scopes.contains('provider:poll')` | **Capability**, not a role | `ProviderView` opens the join form |
| `canManageProvider` = `isOwner \|\| isProvider` | | The Members tab |

**Inviting is open to members; removing is owner-only.** A grid grows because the people in it can bring
someone; taking someone out is a different act. The invite reaches the same dialog from two places (the
account menu's "Share grid" and the grid's detail screen) — one `ShareGridDialog`, not two lookalikes.

#### `GridAccess` — who can reach a grid, in the three shapes the control plane ships

`gridAccessFor(network_type)` maps by **substring**, checking `domain` first, and an unknown future variant
lands on the **narrowest** reading:

| wire `network_type` | `GridAccess` | Means |
|---|---|---|
| `permissioned-public` | `restricted` | providers **and** consumers whitelisted — invite-only. *The word "public" in the wire value is the one that lies* |
| `private-domain` | `domain` | an organisation's grid, named for its email domain — **also invite-only** |
| `permissionless` | `anyone` | only providers whitelisted, so anyone signed in can consume |

> ⚠️ **`domain` was first read the other way**, from the name and an analogy with Google Workspace rather
> than from anything the product does — and the dialog told users their grid was open to their whole company
> when it wasn't. The evidence was in the repo the whole time: `NetworkCredential.isPublic` keys off
> `providers`, so this type has always resolved to Private.

**Invite email validation is client-side and deliberately not RFC 5322** (`invite_email.dart`): that grammar
allows quoted strings, comments and bracketed IP literals nobody types into an invite box, and implementing
it would *accept* more junk than it rejects. **The server is still the validator** — the point of the local
check is that a 422 comes back as one flat "Invalid email" while this can name the half that's broken, and
the checks run from the mistake a person is most likely to have made to the most obscure.

#### Per-node token telemetry — `answered`

`OverviewNode.answered` (`NodeAnswered` + `AnsweredModel`, both `with AnsweredTokens`) carries what a node
produced inside the relay's rollup window, with a per-model split and the window length **as the relay
reported it** (an operator knob — a label hardcoded to "24h" goes quietly wrong the moment someone retunes
it). Shown on the grid pill, the stat panels and the node dashboard card.

- **`tokensCached` is part of `tokensIn`, never additional to it.** The relay bills
  `(in − cached)·input + cached·cache + out·output`, so the grand total is `in + out`; anything adding cache
  on top counts the cached prefill twice. `freshInputTokens` is the leg a three-way split needs.
- **Present-with-zeros ≠ absent.** A node measured and found idle sends real zeros and the dashboard prints
  `0`; a relay too old to compute this sends no `answered` object and it prints `—` (`kUnmeasured`). That is
  the whole reason it is a nullable object rather than a pair of ints defaulting to 0 — and the same rule
  every other row on the card follows: the figure reads `0%` vs `—`, **and** the bar is a solid empty track
  vs a dashed one. Neither alone is enough; do not drop one as redundant.
- `OverviewModel.vision` is tri-state for the same reason — `null` means the relay didn't say, and reading
  absence as `false` would misreport every model from an older relay. The composer's vision lock (§7.1)
  treats "not in the list" as "can't be trusted with an image", which is the safe direction.

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

- **`isPublic` is deliberately inverted**: `permissionless` = **Public**, `permissioned-public` =
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

#### Voice into the composer

`RecordingController` (sealed `RecordingPhase`: idle / active / transcribing / failed) sits over two seams:
`MicRecorder` (a thin interface over `package:record`, so a fake drives it in tests instead of a real
microphone) and `SttClient`.

```
mic tap → hasPermission() → record 16-bit WAV into a temp clip dir
mic tap → stop() → grid stt transcribe <path> --lang <en|vi> → transcript into the INPUT FIELD
```

- **The transcription goes through the CLI, not straight to the endpoint** — conventions §7: every `grid`
  call goes through `GridCliService`, and the control-plane speech endpoint wants the session token the app
  deliberately doesn't handle. The file **stays on disk** and is passed by path, like every other
  file-passing command here.
- **`sttClientProvider` is null when `grid` can't be resolved**, and the mic button then disables itself
  with a reason rather than spawning a command that can't run — the same gate every CLI-backed feature uses.
- **An empty transcript is a normal answer, not a failure**: silence, or speech in a language other than the
  one pinned. Only a non-2xx or a transport error becomes `RecordingFailed`, and `_messageForStatus` maps
  401/400/413/503 to sentences a user can act on.
- The result never touches `chatControllerProvider` — a recording produces *input*, not a turn.

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

**Welcome screen** — one screen, once, after setup and immediately before the app (§6). It argues the
product rather than explaining it: `grid_growth.dart` is a pure timeline of machines joining
(`kWelcomeMachines`, polar and **relative** — angle plus a radius multiplier of whatever ellipse the band
computes for its own size, so the cluster keeps its shape in a narrow window), drawn by `GridGrowthBand` /
`GridGrowthPainter` beside a `CapacityRail`. The first machine is the user's own, alone at the centre —
that is the "before" the rest of the screen argues against. `WelcomeStore` reads a missing or corrupt file
as **not shown yet**: erring that way costs a returning user one extra screen, the other way hides it from
the person it was written for.

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

### 7.17. `prompts/` — **deleted 2026-08-17**

The `/` library of named boilerplate is gone: the whole domain, its `prompts.json` entry in the sync
snapshot, and `GridPaths.promptsFile`. The slash it owned now runs the commands the app performs itself
(§7.1). What survived the move is the one part that was doing real work — `slashQuery`, which requires a
leading `/` and **no whitespace** after it (`/a b` → null, the user is writing a real sentence) — now in
`chat/logic/commands/chat_command.dart` beside the parse and the menu's prefix match.

**Nothing deletes `~/.grid/app/prompts.json`.** A user's saved prompts stay on disk, unread, rather than
being thrown away by a version they never chose to install.

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

`upload()` packs the machine's data — chats (`~/.grid/app/chats/`), projects (`projects.json`), and media
under `~/.grid/outputs/` — into an encrypted envelope. (`prompts.json` left the snapshot with the `prompts/`
domain on 2026-08-17; a few doc comments in `sync_*` still name it.) `download()` decrypts and
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

### 7.30. `panel/` — the Grid Panel on the desk

**Owns:** the app's side of the conversation with a physical **Grid Panel** — an ESP32 board with a
480×480 screen, plugged in by USB, that shows what each project is doing and lets the user start, stop or
**speak** a turn without touching the window. **8 files, ~3,180 lines**, over the Flutter-free wire in
`lib/infrastructure/panel/` (9 files, ~1,770 lines — §4.7) and opened by `lib/app/panel_scope.dart` (§6).
The domain is `logic/` only: the panel draws on the device, so there is nothing here to render.

#### `PanelController` — the switchboard

`ref.listen`s **two** providers, because a turn moves in two places: `chatSessionsProvider` says a turn is
happening, `agentRunsProvider` says what it has done so far. `PanelTurnMirror` is what makes that
affordable — a turn publishes a phase per streamed token, and the mirror **says nothing when nothing the
panel can draw has moved**.

| Panel says | The app does |
|---|---|
| `hello` | log it, **answer even on a protocol mismatch** (the panel only learns which version to reflash to from the `welcome` it gets back), push the turns already in flight (`onAttach` — a panel plugged in mid-turn knows nothing about work already running), then offer firmware |
| `projects.list` | `panelProjectsFor(...)` — every project **in the order the app itself lists them**, so the panel and the rail never disagree about which is first |
| `turn.send` | start a turn in the project's **most recently used** chat, or a new one — the same place the window would put it |
| `turn.stop` | stop **every** conversation in that project, not one: a project is what the tile is, and which chat holds the turn is the desktop's business |
| `voice.begin` / PCM / `voice.end` / `voice.confirm` | capture → `grid stt transcribe` → route (below) |
| `answer` | settle a permission the agent is waiting on (below) |
| `firmware.*` | drive `PanelFirmwareUpdater` |
| an unknown or malformed message | **logged, never fatal** |

It also **pushes four things the panel never asks for**, each through its own mirror so the "say nothing
when nothing changed" rule holds per concern:

| Push | Mirror | Note |
|---|---|---|
| `turn.started` / `turn.parts` / `turn.done` / `turn.error` | `panel_turn_mirror.dart` | below |
| `projects` / `project.updated` | `panel_project_mirror.dart` | the tile list is **not** pull-only any more — a project created at the desktop reaches a plugged-in panel without a replug |
| `question` / `question.cancel` | `panel_question_mirror.dart` | from `agentPermissionsProvider`, keyed by chat and mapped to a project by the same `panelTurnHoldersOf()` the turns use |
| `summary` | `panel_summary_writer.dart` | one-shot model call at turn end (below) |
| `ping` | a 5s timer in `PanelController` | cancelled in `stop()` with the rest |

**Every refusal is answered in words** (`turn.error`) — no words in the message, the project is gone from
this computer, that project is already working, no grid is open, no model available, the send threw.
Silence would leave the tile spinning on work that is never coming, **and the panel has no other way to
find out**: it runs no model, reads no disk and cannot see the window.

**`_dispatchTurn` is deliberately not awaited.** `send()` completes when the *turn* does — minutes for an
agent — and the panel's next message, **Stop most of all**, must not queue behind it. Everything after
that point reaches the panel through `mirrorTurns()`.

**Starting a turn in a project nobody has talked in yet opens it in the window**, unlike every other send
the app makes on its own. The user did ask for it, just from the other side of the desk, and a reply
landing in a chat the window never shows is a reply they have to go hunting for.

**`_modelFor` takes the remembered choice as it stands** — project's model → that chat's last → the app's
standing choice → whatever the grid serves — and does **not** check it against the grid's list. That list
is fetched, and empty for the first moment of a session and on every refresh; checking would turn a panel
turn into "no model available" over a grid serving a dozen.

#### `PanelTurnMirror` — a turn as a bounded timeline

Sends `turn.parts` **whole on every change, not as a delta**: the `AgentRun` is replaced wholesale
upstream and a step mutates in place as it finishes, so there is no append-only stream underneath to
mirror. It is the same `TurnPart` list §4.3 describes, which is what keeps the tile and the transcript
telling one story.

- `kPanelTurnPartLimit = 12`, `kPanelPartTextLimit = 200`, then drop **oldest-first** until the encoded
  frame fits 8192 bytes — a character cap is an average, not a bound (200 characters of CJK is three times
  the bytes of English). What survives is **the tail** of the turn, which is what a live tile wants anyway.
- `panelTurnInFlight = sendingFor(id) || agentRunningIn(id)` — the union on purpose. Either alone leaves a
  gap where the project is working and the panel says it is idle.
- A step carries `label`, `status`, and — when known — `tool`, `arg` (the raw argument),
  `kind` (`command`/`web`/`tool`/`thinking`, **which is what picks the colour**; the device must not
  infer one from the tool's name), `parent` (the step that spawned it → the sub-agent band) and `t0`.
  Its *result* still stays in the app's transcript: a 466px tile has nowhere to draw it.
- **`t0` is a fixed number, and that is the point.** It is milliseconds from `turn.started` to when the
  step started — *not* live elapsed. Sending elapsed would change the payload every second, defeat the
  dedup below, and put ~3 KB on the wire per tick for a number the device can count itself. The device
  must not stamp steps when it first sees them either: `onAttach` re-sends the whole timeline after a
  panel reboot, and every step would read as having just begun.
- `todos[]` rides the **message**, not the parts — a plan is a state, not a point in the story.
- `status` has **four** values and the fourth is the one that bites: `unknown` = the turn ended without
  this step ever reporting. **A reader must treat anything it doesn't recognise as finished, never as
  running** — the alternative is a spinner turning forever on a turn that ended.

> ⚠️ **A todo's status is a different vocabulary, and its default runs the other way.**
> `pending` / `running` / `done`, and **an unrecognised todo status is drawn as `pending`, never as
> done.** The two rules are opposite because the two failure modes are opposite: an unrecognised *step*
> left spinning claims work is happening that isn't, while an unrecognised *todo* ticked claims work
> nobody has begun is finished. `_todoStatus` in `panel_turn_mirror.dart` therefore writes the three
> words out rather than borrowing `AgentActivityStatus` — two of them are spelled the same, and that
> is exactly what made routing `pending` through `unknown` look reasonable. A plan has no equivalent
> of "ran, but never reported back".

#### Questions — two surfaces racing on purpose

The same permission is on screen twice: pinned above the composer in the window, and as a card on the
panel. `panel_question_mirror.dart` keeps them one thing.

- `AgentPermissionController` is keyed by **chat**; a tile is a **project**. The mirror reuses
  `panelTurnHoldersOf()` rather than growing a second mapping that could disagree with the turns'.
- **`question.cancel` goes to the panel that answered, too.** Not special-casing your own answer is what
  keeps one code path instead of two — and the same message covers the app's 55s timeout giving up.
- An `answer` for a request already settled is **dropped silently**. The race is the design, not a bug.
- **`options` is what the app can actually deliver** — 1, 2 or 3, never a fixed pair. It is deliberately
  narrower than what the agent offered: the widest grant (`allow_always`, which Hermes would persist
  forever) is one the app refuses to hand out, and a button whose only outcome is a refusal is worse
  than no button.
- **All three agents ask now** (§4.3), so a card can come from any of them. It used to be Hermes alone,
  and a panel that never showed one was normal; today a run that never asks means the mode allows it.

#### The summary — a second message, deliberately late

`turn.done.recap` is one line, enough for a tile. The detail screen wants prose, so
`panel_summary_writer.dart` asks a model for it at turn end through the **already-shared one-shot seam**
(`resolveOneShotTarget` + `chatTransportProvider.complete`, the same path the commit-message writer and
the skill generator use — §7.22).

Four rules, each avoiding a specific wrong answer: `turn.done` **never waits for it** (a tile spinning
on finished work); it runs **only when a panel is connected** (otherwise every turn buys a model call
for nobody); a failure sends **nothing** and logs, so the reader says "nothing more to show" rather than
loading forever; and it can follow **`turn.error` as well as `turn.done`** — a turn that broke halfway
may still have said something worth reading.

#### Voice — the panel captures, the app transcribes

The device holds **no cloud credential and never talks to one**. Audio (16 kHz mono 16-bit PCM, frame type
`0x02`) rides its own stream, off the message stream, and is subscribed to **for the whole session** —
both are broadcast with no buffer, so subscribing at `voice.begin` would miss the chunks already in flight
behind it: *the first syllable of every sentence*.

Two caps guarding two different things: `kPanelVoiceMaxBytes` (60s) bounds the **memory**;
`kPanelVoiceOpenLimit` (75s) bounds the **wait**, and is deliberately longer, so a capture that filled up
is closed by the bytes and the timer only ever fires for a panel that went quiet mid-sentence.

> **Routing is the hard half, not transcription.** When `voice.begin` names a project the transcript goes
> there. When it doesn't, the app has to guess — and **a guess that dispatches itself into a real
> repository is worse than one extra tap**, so it answers `needsConfirm: true` and holds the words
> (`_guessed`, keyed by a session-unique route id, max `kPanelVoicePendingLimit = 4`, dropped
> oldest-first) until `voice.confirm` says where they go. A panel that ignores `needsConfirm` and
> dispatches anyway defeats the only guard there is.

`cmd` (`goal` / `loop`) is **a prefix, not a mode** — the panel's three pills say what *kind* of thing the
sentence is.

#### Firmware — the app reflashes the device it is talking to

Three pieces of session state, each preventing a specific loop that would otherwise cost the user's
hardware:

| Guard | Stops |
|---|---|
| `_flashed[mac]` = the version reported **before** the update | a panel that comes back still calling itself the old version being flashed again, **forever** |
| `_refused[mac]` = image versions this session already failed to hand over | a retry on **every `hello`** — every fifteen seconds while the cable is in. Not a quiet retry: the panel **erases a flash slot before it answers an offer** |
| `_deferredOffer` | interrupting a running turn. Retried from `mirrorTurns()` the moment the machine goes idle — the panel will not say `hello` again until it is unplugged |

`_refused` is keyed by MAC (two panels can be plugged in, and one failing says nothing about the other)
and is **session-scoped on purpose**: replugging or restarting the app is a deliberate act and earns a
fresh attempt.

#### Tests

`test/panel/` — 6 files covering the frame codec, the link, port discovery, firmware parsing, the
controller and voice, plus `test/vectors/panel_frame.txt` (generated by `scripts/gen_panel_vectors.py`).
This is the exemption conventions §8 grants beyond the grid/agents areas, and the reason is spelled out
there: **a codec never rots, it is pure, and it fails as a desync three layers away from the mistake** —
which running the app diagnoses very badly. `tool/panel_tap.dart` drives the whole protocol against a real
device with no app running.

---

## 8. End-to-end: one chat turn

```
[1] User types into the composer
    chat_composer.dart → ComposerKeys._onKeyEvent
      Enter (no Shift) && canSend → onSend()
      SWALLOW Enter regardless — a turn that couldn't send mustn't drop a stray line break
      a leading /name in ChatCommand → runCommand(call, model: <the picker's>) and STOP: the app
      performs it, nothing goes on the wire (§7.1)

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
                  turnModelUsage.begin(chatId, network)   ← the /usage window opens 5s EARLY
                                                            (two clocks; a caption that misses the turn's
                                                             first request is worse than one stray)
                  conversation.resume → sender(resume:)   ← adopted only if agent AND workdir match

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

┌───────────────── BRANCH C: CODEX (app-server, JSON-RPC, 1 server/turn) ──────────────────────┐
│ [6c] codex app-server --stdio  -c <the run's config>                                         │
│        -c model / model_provider / model_providers.grid-app.{name,base_url,env_key,           │
│           wire_api="responses", supports_websockets=false}                                    │
│        the SANDBOX is no longer among them — it is negotiated per thread, from the chat's     │
│        mode: codexApprovalPolicy(readOnly→never/read-only · plan,ask→untrusted/workspace-write │
│                                  · full→never/danger-full-access)                             │
│      handshake ≤ kCodexHandshakeTimeout (45s, covers a cold start) → newThread(cwd) or resume │
│      env {GRID_APP_API_KEY}  ← NOT GRID_API_KEY: Codex loads ~/.codex/.env and that           │
│                                dotenv WINS over the parent process env                        │
│ [7c] codex_app_server_parser: agent_message (WHOLE text) · command_execution/web_search/      │
│      mcp_tool_call · todo_list → plan · file_change (only when status == completed)           │
│      item/*/requestApproval → decideAgentPermission → the card above the composer (§7.2)      │
│      no `app-server` in this build → SAY SO (kCodexNoAppServer); never fall back to `exec`,   │
│      which would be the app promising to ask and then not asking                              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────── BRANCH D: CLAUDE CODE (-p, 1 process/turn) ─────────────────────────┐
│ [6d] planClaudeBrowser() → lane extension / cdp / none (every outcome logged WITH ITS REASON) │
│      ClaudeTurnMcpConfig().write(extra) → ~/.grid/app/claude-mcp-config.json                  │
│        read ~/.claude.json, keep ONLY entries marked `_grid`, + browser extra                 │
│        write fails → null → DROP BOTH FLAGS (a nonexistent path kills the turn)               │
│ [7d] claude -p --input-format stream-json --output-format stream-json                         │
│        --include-partial-messages --verbose --model <m>                                       │
│        --permission-mode default --permission-prompt-tool stdio         ← IT ASKS NOW         │
│        [--chrome] [--disallowedTools <server web tools>] [--mcp-config <p>                    │
│         --strict-mcp-config] [--resume <sid>]                                                 │
│      can_use_tool over the stdin control channel → decideAgentPermission → the card (§7.2)    │
│      env: claudeCodeEnv(...) — ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL/…                  │
│           lane extension → EMPTY env + dropEnvironment: kClaudeRelayEnvKeys                    │
│      prompt over STDIN, as a JSON envelope (the input format is stream-json both ways now)     │
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

[10b] Each new step closes a passage:  runs.upsertStep(chat, activity, answer: <what's been said>)
        → AgentRun.parts grows as an ORDERED timeline (TurnText | TurnStep) — §4.3
        → Claude passes the SETTLED text, not the streaming one: a sub-agent's step can land between two
          deltas of a sentence, and dividing the turn there would split that sentence around it

[11] chat_sessions_settle.dart  updates.listen — fold the sealed ChatSendUpdate
       ChatSendGenerating  → withPhase(SendGenerating)
       ChatSendStreaming   → firstToken = clock.elapsed (first non-blank text)
                             withPhase(SendStreaming(text))  ← text is the WHOLE thing, UI REPLACES not appends
       ChatSendAgentSession→ remember the sessionId
       ChatSendSuccess     → say(chat, answer) closes the last passage → settledParts() (no row left
                             "running") stamped onto the reply, with the shares polled so far
                             → conversation.resume = _resumePointFor(...)   ← null LEAVES the old point
                               (a relay turn — a picture — has no session and must not erase the agent's)
                             → append the reply, _commit(SendIdle), _adoptAgentName, _announceTurn
                             → unawaited _settleModelShares: turnModelUsage.end()'s last reading corrects
                               the caption a moment later, re-committing under the chat's CURRENT phase
                               (the user may already have asked the next question). Only ever upward —
                               empty/404/deleted leaves the stamped value alone
       ChatSendFailure     → KEEP the streamed part (partial ?? SendStreaming.text)
       Every update checks _find(id) == null → a chat deleted mid-turn is dropped, not resurrected

[12] _finish(id) → _releaseAgentSlot → _drainQueue(id) FIRST; only an empty queue then the goal's judge
       goal running? → a second model reads the transcript → MET/IMPOSSIBLE stops it, NOT_YET sends the
                       next turn with the evaluator's reason (a failed or stopped turn is NOT judged)
       loop running? → _scheduleNextIteration: the user's gap, the pace the assistant picked, or 3s

[13] Render: _Transcript caches the widget by the IDENTITY of a ChatMessage
       → MessageContent → parseMessageSegments → SelectionArea → MarkdownBody
       → ```chart fence → ChartSpec.parse → MessageChart (CustomPaint)
       → media → InlineImage / InlineVideo (media_kit) / InlineAudio

[14] _announceTurn → notificationIsWorthIt(appFocused, userIsLookingAtIt) = !(both)
       → DesktopNotification(opens: conversation.id) → click → revealChat()
```

---

## 9. Design system

`lib/shared/theme/app_theme.dart` (**1,450 lines**) is the **whole** system.
Canonical spec: [`docs/style-guide-grid-app.md`](style-guide-grid-app.md) — spacing, radii, toolbar metrics,
the one-bright-row rule. (`docs/design-system.md`, which earlier versions of this note pointed at, **no
longer exists**; conventions §4 names the style guide instead.)

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
| `AppPalette` | Base colours | `windowBg` #FFFFFF / #181818 · `panelBg` #F9F9F8 / #141414 · `cardBg` #F3F3F2 / #1E1E1E |
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
**directly**, through every `const` boundary. **There are currently 573 `AppTheme.watch` call sites** in
`lib/` (measured 2026-08-17).

**Quick audit:** count token reads vs `AppTheme.watch` in a module — reads > 0 with watch == 0 is a certain
theme-flip bug.

### Traps pinned by comment

- **`windowBg` is the *page* background, not a raised surface.** A dialog taking `windowBg` is **the page's
  own colour** — 1.000:1, no edge at all — and dark `#181818` also sits *above* panel `#141414`, so a panel
  fill there reads as a hole rather than a block. In light this bug is **invisible**
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
  constant and the menu drifts off the button. There is now **one recipe** for the maths:
  `shared/widgets/anchored_menu_position.dart` (`anchoredMenuPosition` for a `BuildContext`,
  `anchoredMenuOffset` pure for the arithmetic), used by 12 call sites. `MenuAnchor` clamps an oversized
  menu against the window edge *after* resolving the anchor, so a small pill near an edge had its offsets
  quietly ignored; this picks an in-bounds overlay position first. A menu always grows **down** from the
  offset it opens at, so one opening upward is placed at "anchor top − its own height" — which makes the
  caller's height estimate load-bearing, and an **over**-estimate lifts the panel clear of its button (the
  chat model picker predicted 310 for a panel that drew 240 and hung 70px up in the conversation). The
  estimate is therefore clamped to `maxHeight` here rather than at each call site. An **under**-estimate,
  like `chat_header`'s (§7.1), is the case neither end corrects
- **The gap between a pill and its menu is one token** — `AppControl.menuGap`. It became one because every
  one of the ten callers was passing `gap: 6` to override a default of 8 that nobody wanted

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
| Chat + agent (3 runtimes + Auto) | ✅ **Shipped** | 957-line controller + 6 part files, resume/queue/plan, turn timeline. Auto is **devOnly** |
| **Chat commands** (`/clear`, `/compact`, `/goal`, `/loop`) | ✅ **Shipped** | `chat/logic/commands/` (pure) + two controller parts; the `/` menu; `prompts/` deleted for them; §7.1 |
| **A chat is written off the UI isolate** | ✅ **Shipped** | `ChatStore` spawns an isolate per write, newest-snapshot-per-chat; `loadAll()` awaits what's in flight |
| **Import chats (Claude Code, Codex)** | ✅ **Shipped** | Scanner + 2 parsers + ledger + sync, `ImportSessionsView`; §7.1 |
| **Resume across a quit** | ✅ **Shipped** | `AgentResumePoint` on the conversation; Claude + Codex only (Hermes has no on-disk session) |
| **Which models served a turn** | ⚠️ **Needs a new relay** | `GET /relay/v1/usage`; an older master 404s and the caption stays empty — by design, but it means most grids show nothing yet |
| **Voice into the composer** | ✅ Shipped | `grid stt transcribe`; disabled with a reason when `grid` can't be resolved |
| **Welcome screen** | ✅ Shipped | One-time, `~/.grid/app/welcome.json`; §7.14 |
| **Share a grid / invite** | ✅ Shipped | One dialog from two entry points; invites open to members, removal owner-only |
| **Panels around chat** | ✅ **Shipped** | 3 hosts × 3 features, tab strip, drag seam, expanded; geometry is pure — but `resolveSidePanel` **has no test** (§13) |
| **Review** | ✅ **Shipped** | 6 scopes, stage/commit/push, line comments, AI commit message, split/unified |
| **Terminal** | ✅ **Shipped** | real pty, 10k scrollback, attachable to a message |
| **Files** | ✅ **Shipped** | tree + breadcrumb + viewer, 2-mode Markdown, "Add to chat" |
| **Git (install/adopt)** | ✅ Shipped | Background install + Settings ▸ Coding ▸ Git |
| **Code half (shared repos)** | 🔒 **devOnly** | ProjectFlow catch-up/publish, task transcript, PanelHost.code — relay has no projects plane in prod |
| **Grid Panel (USB device)** | ✅ **Both halves, on `main`** | App half: protocol, controller, 4 mirrors, voice, reflash, **180 tests in 8 files**. Device half: `device/esp32-circle/` — the Waveshare 466×466 round board, ported from the reference by **deletion** (7,243 → 4,546 lines of `ui_screens.c`, everything else byte-identical), builds to a 2.1 MB image with 74% of the OTA slot free. `docs/panel-protocol.md` is the only thing the two share. §4.7, §7.30 |
| **Sync & Backup** | ✅ Shipped | Encrypted upload/download + merge; §7.27 |
| **Feedback** | ⚠️ **Consent surface gone, the behaviour stayed** | The commented-out `AttachLogsField` lines have been deleted, but `_attachLogs` is still `true` and written by nothing, so `_send()` always zips and uploads `~/.grid/logs` **unseen**. It is the repo's only analyzer issue. §13 |
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
| Composio | ❌ **Not one line of Dart** | grep the whole of `lib/`: nothing mentions it |
| Windows auto-update | ❌ Deferred | `isSupported => Platform.isMacOS` |
| `GridResolver.configuredPath` | ❌ Not wired to UI | `providers.dart` builds a bare `GridResolver()` |
| Agent switcher (Skills/Connectors/Plugins) | ❌ Not built | `extensionAgentProvider` **always** returns `hermes` |
| Approval for every agent | ✅ **Shipped 08/18** | Codex over `codex app-server`, Claude Code over `--permission-prompt-tool` + stdin `stream-json`, Hermes over ACP — one `decideAgentPermission` behind all three (§7.2) |

---

## 11. The most important invariants

This list is things that **each was once a real bug**. Reversing one recreates the bug.

### Security / safety

1. **Secrets go only through the `environment` channel, never into argv.** The log records only the *name* of
   a variable; the `Authorization` header is never written
2. **`ConnectorBridge` authenticates nothing** — the only fence is the loopback-only bind
3. **Every agent asks now, through one decision.** `decideAgentPermission` is the single place the
    composer's mode is turned into an answer — Hermes over ACP, Codex over the app-server, Claude Code over
    `--permission-prompt-tool`. Two rules inside it are load-bearing: `allow_always` is **never** handed out
    (it would outlive the chat), and a transport that can't remember "allow in this chat" has it remembered
    **for** it (`grantKey`). Reversing any of this puts back the state where the picker promised something
    the app didn't do
4. **The Telegram/Discord/Slack bot allowlist is a security boundary**, not a convenience — toolset pinning
   was removed
5. **A refresh-token failure NEVER deletes anything** — the `refresh_token` is the one thing that can still
   recover
6. **`ready` from `/poll` arrives only once** → write disk before anything else, confirm by **reading it back**
7. **A resume point is used only when its agent AND its folder match** (`AgentResumePoint.matches`) — the
   right id in the wrong folder *succeeds*, and the agent carries on editing files this turn isn't looking at
8. **A relay key is never written next to another grid's URL** (`relayCredentialMismatch`) — the grid id is
   in the URL's **path** and in the token's `aud`, and pairing them wrong reaches the user as the assistant
   failing mid-turn
9. **Another tool's session files are read-only** — `~/.claude/projects`, `~/.codex/sessions`

### Process lifecycle

10. **Need BOTH `onWindowClose` AND `didRequestAppExit`** — `setPreventClose` doesn't cover ⌘Q
11. **`grid leave` deliberately carries no `--engine`** in remote mode
12. **`resetAgentFeed()` must run synchronously, before any `await`**
13. **`slot.seen++` / `live.seen++` only on a successful turn**
14. **`StdioLineWriter` queues rather than writing straight through** — `IOSink.flush()` *binds* the sink; a
    write slipping in between throws and **loses that line** (once hung Hermes for nearly 6 minutes)
15. **Closing a panel tab must `endSession(tabId)`** — an orphaned pty is a process the user can no longer see
    to stop. Called from `PanelTabs.close()`, **not** a watcher (a watcher runs only while someone is looking)
16. **Kill a shell with `SIGHUP`** (Windows: `SIGTERM`) — `SIGTERM` leaves the shell's children holding a pty
    nobody reads
17. **`git` runs with `GIT_TERMINAL_PROMPT=0` + `ssh -o BatchMode=yes`** — the app has no terminal, so a
    prompt nobody can answer hangs until the timeout
18. **macOS: never exec `/usr/bin/git`** — it's an `xcode-select` stub, and running it **pops Apple's
    installer**; resolve via `xcode-select -p` and use an absolute path

### Data

19. **`archivedAt` uses `_parseNullableDate`**, not `_parseDate` (epoch fallback)
20. **`copyWith` can't unset via `?? this.x`** → needs a flag: `clearArchivedAt`, `clearGoal`,
    `clearUiFontFamily`, `clearCategory`, `clearOutgoing`…
21. **Everything that reads chat history uses `state.live`**, not `.conversations`
22. **`saveRefreshed` merges, doesn't assign**
23. **`null` ≠ `ConnectorTransport.none`**; **`advertises_*` is tri-state**, `null` ≠ `false`
24. **An empty `served` = "not loaded yet"**, not "the grid serves nothing"
25. **A chat is written off the UI isolate, and a read waits for the writes in flight.** `ChatStore` keeps
    the newest snapshot per chat (not a queue — two commits in a breath are two versions of one file) and
    `_inFlight` is **static**, because the folder is the shared thing, not the object: a second store over
    the same directory must not read a file mid-write
26. **A loop that arrives in a restored backup is stopped, not adopted** — the machine it came from holds
    the timer, and the difference is invisible from this side; adopting it either doubles every turn or
    counts down to a beat nobody arms
27. **A loop turn is cancelled only after 60 minutes of *no progress*, never on wall-clock** — a turn still
    streaming is doing the work that was asked for
28. **A step stored as `running` reads back as `unknown`**, at both ends (`settledParts` on the way out,
    `_statusByName` on the way in) — a turn that ended is over, and a spinner in last week's transcript is a
    chat that looks like it is still working on something nothing is working on
29. **`resume: null` from a turn leaves the old point standing** — a relay turn (a picture) has no session of
    its own and must not erase the one the agent is still holding
30. **The import ledger is read against the chats that exist** — a record whose chat was deleted must offer
    the session again, not hide it forever

### Riverpod / render

31. **`gridOverviewSnapshot` is the only door** — `.asData` zeroes the numbers per poll; watching both an
    `AsyncValue` and a family in one body → `setState() during build`
32. **Value equality on `GridOverview` is load-bearing**
33. **`routeFor` takes a `GridOverview?`, not an `AsyncValue`**
34. **`CommandLogNotifier._schedule` = `Future.microtask`** is mandatory, not an optimisation
35. **Every widget that reads a token must call `AppTheme.watch(context)`**

### Wire protocol

36. **`ChatSendStreaming.text` is the WHOLE text; `ChatDelta.text` is a fragment.** Hermes's message is a
    **delta**; Claude/Codex are **whole text**
37. **`--mcp-config` must come with `--strict-mcp-config`**; a broken write → `null` → drop **both**
38. **The Codex sandbox is negotiated per thread, not passed as `-c`** — it follows the chat's mode
    (`codexApprovalPolicy`), while the grid/model/provider `-c` overrides still ride **every** turn. Under
    the old `codex exec` transport this line read "`exec resume` takes neither `--sandbox` nor `-C`"; the
    trap it recorded — flags are per-subcommand, and a wrong one fails exactly like a model that wouldn't
    answer — is why `codexAppServerArgs` is a pure, tested function
39. **`Accept: application/json, text/event-stream`** — both required (Canva returns 406)
40. **SSE takes the LAST `data:`**, not the first
41. **`CliResult.sessionExpired` is a string-match on four English sentences** — a CLI wording change makes
    the app silently stop detecting it
42. **`GET /relay/v1/usage` answering 404 means "no data yet"**, never an error the user sees — every grid
    whose master predates the endpoint answers that way
43. **A panel frame type this build can't read is surfaced, not dropped** — a peer running ahead must read
    as a version mismatch someone can act on, never as a link that connects and then goes quiet
44. **Resyncing the panel stream discards ONE byte on a bad length or CRC**, not the candidate frame — the
    magic may have been a coincidence inside noise, and a real frame can start one byte further in
45. **A step `status` you don't recognise is FINISHED, never running** — `unknown` is what a step settles
    to when the turn ended without it reporting, and reading it as running leaves a spinner turning forever
46. **A *todo* status you don't recognise is PENDING, never done** — the opposite default to #45, because
    the opposite mistake is the costly one: a tick against work nobody has begun. The two must not share
    an enum, however alike the words look
47. **What the panel is told must never be a live number.** `t0` is a fixed offset, not elapsed seconds;
    a value that changes every second defeats `PanelTurnMirror`'s payload comparison and turns an idle
    cable into 3 KB/s. Anything that ticks is the device's job to count

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

**Measured on `main`, 2026-08-18:**

| | Result |
|---|---|
| `flutter analyze lib test` | **1 issue** — `features/feedback/presentation/feedback_dialog.dart`: `_attachLogs` could be `final`. The unused import went with the commented-out widget; the field the linter is pointing at is the behaviour change that outlived it (§13) |
| `flutter test --concurrency=12` | **2204 passing, 0 failing**, 188 files, **26s** wall clock |
| Widget tests | **0** — `grep -rl 'testWidgets\|pumpWidget\|WidgetTester' test` is empty, as §8 of the conventions requires |
| Test areas | the 14 the conventions name, **plus `code/` and `panel/`** |

> **The bar is 0 analyzer issues, and the repo is not at it.** That one is the only one, and it is the
> visible end of a real behaviour change — not lint noise to wave through.
> Re-measure before quoting any of this; the numbers in this table have gone stale repeatedly.
>
> ⚠️ **Two tests in `test/chat` flake on a temp directory, not on their assertions** (seen 2026-08-18):
> `tearDown`'s `Directory.delete` loses a race with a write that is now off-isolate, and the failure reads
> `Directory not empty`. A rerun is green. It is a real hole in the harness — a test that fails for a
> reason unrelated to what it checks teaches people to rerun rather than read.

### Build & release

```bash
./scripts/bundle_grid_macos.sh     # build the app + inject the Nuitka onefile sidecar
./scripts/package_dmg_macos.sh     # ad-hoc DMG
DEV_ID="…" NOTARY_PROFILE=grid-notary ./scripts/notarize_macos.sh
```

Push a `v*` tag → `.github/workflows/release.yml` → a draft release with
`Grid-<ver>-macOS-Apple-Silicon.dmg` + `Grid-<ver>-macOS-Intel.dmg` (both signed + notarized).
The Windows job is commented out until code-signing exists.

Two things in that workflow are load-bearing, and both were bugs that shipped:

- **Flutter is pinned (`flutter-version: 3.44.4`), not just `channel: stable`.** An unpinned stable built
  v0.3.41+ on an engine two minor versions ahead of the one the team develops on, and the shipped DMG
  rendered corrupt — proven by diffing the shipped `FlutterMacOS` against a local build. `channel: stable`
  alone is not a version.
- **The Intel DMG ships with `FLTEnableImpeller = false`.** On an Intel Mac under Impeller the whole content
  layer fails to rasterize a few times a second and is replaced by fans of stretched geometry, while the
  sidebar beside it keeps drawing (screen recording, 2026-08-17). The key is written into `Info.plist`
  **before signing** and **read back**, because a build that silently kept Impeller looks exactly like a fix
  that didn't work. Apple Silicon is untouched. `TODO(BE)`: a workaround, not a diagnosis — Intel users now
  run a backend nothing we test runs on, so re-check it on every Flutter bump.

**Not bundled at runtime:** `llama-server` (`grid engine install llama.cpp`), ComfyUI
(`grid media install`). Provider node targets **macOS Apple Silicon** and **Linux NVIDIA**; on Windows the
app is effectively consumer/playground only.

---

## 13. Technical debt

### Dependency-direction violations (§1 conventions: `presentation → logic → infrastructure`, not the reverse)

| From | To |
|---|---|
| **`infrastructure/api/relay_api_client.dart`** (**new, 08/17**) | `features/chat/logic/turn_model_share.dart` — `ModelShare` is the wire shape of `GET /relay/v1/usage` and belongs in `infrastructure/api/models/`, beside `GridOverview`. Same root cause as every edge below: a DTO parked in a feature |
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
| `chat` ⇄ `agents` (**new, 08/17**) | `chat/logic/import/session_scanner.dart` → `agents/logic/agent_prompt.dart`; back the other way `agents/presentation/agent_working_bubble.dart` → `chat/logic/turn_model_{share,usage}.dart` | logic ⇄ **presentation** |

**`panel/` has the widest fan-out in the repo, and every edge points out.** Its `logic/` reads six other
domains — `chat` (7 imports), `projects` (5), `playground` (4), `agents` (3), `provider_node`, `auth` —
while **nothing imports `panel/`** except `app/panel_scope.dart` (re-measured 2026-08-18). That direction is the
domain's whole point: the panel is a *second view of the same state*, so it must read the providers the
window reads rather than keep its own (§7.30). Watch it — the day a feature imports `panel/` to "tell the
panel something", the boundary is gone and the panel becomes a second source of truth, the exact bug §7.30
exists to avoid.

The `chat` ⇄ `terminal` pair is **one-way** and deliberate: `terminal/` doesn't know what a panel is
(*"a terminal has no business knowing what a panel is"*), so `chat/` (via `shared/panels`) calls `endSession`
rather than the reverse. That's the right shape — only the last step is missing: moving `TerminalCapture` down
to `shared/`.

### Choke-point types — change one and many places break

| Type | Where | Fragility |
|---|---|---|
| `GridCliService` (3 methods) | `cli/grid_cli_service.dart:76` | many call sites, one build point. `sessionExpired` is a **4-English-sentence string-match** |
| `ChatSendUpdate` (sealed 5) | `playground/logic/chat_sender.dart:23` | the merge point of **all four** sending paths |
| `Conversation` | `chat/logic/conversation.dart` | 6 domains read it; `archivedAt` a timestamp; needs `clear*` flags; now also carries `resume` (**set-only** in `copyWith`) and each message's `parts` + `modelShares` |
| `TurnPart` (sealed 2) + `AgentActivity` | `infrastructure/cli/agent_turn_part.dart`, `agent_event.dart` | every agent parser writes them, the transcript and the live bubble both read them, and they are **serialized to disk** — a field rename silently blanks old chats (the `tool`/`name` key split is exactly that scar) |
| `NetworkCredential` | `state/models/network_credential.dart` | 3 different permission axes; `isPublic` **deliberately inverted** |
| `ConnectorToken` + `McpEntry` + `RestEntry` | `agents/logic/` | the one type that crosses **all three planes** |
| `AgentExtensions` (3 planes) | `agents/logic/agent_extensions.dart` | **a null plane is a valid answer**, not an error |

### Pure functions that call themselves "testable" but **have no test**

§8 conventions: *"pure logic (parsing, deriving, planning) lives in side-effect-free functions **and is unit
tested**"*. These have a doc comment justifying their purity **by testability** — and then nobody wrote the
test. Re-grepped 2026-08-17:

| Function / module | Lines | The doc comment says | Test |
|---|---|---|---|
| **`chat/logic/import/**`** — `parseClaudeSession`, `parseCodexSession`, `SessionScanner`, `ImportRecord`, `stripInjectedContext` | **~2,100** | *"the only reason they can be trusted against formats that change under us"* | **0** |
| `agent_turn_part.dart` — `unsaidTail`, `settledParts`, `turnPartToJson/FromJson` | 235 | — | **0** |
| `core/relay_identity.dart` — `gridIdFromRelayToken`, `relayCredentialMismatch` | 88 | — | **0** |
| `network/logic/invite_email.dart` | 99 | — | **0** |
| `network/logic/grid_access.dart` | 38 | — | **0** |
| `shared/widgets/anchored_menu_position.dart` — `anchoredMenuOffset` | 109 | *"free of any render tree so it can be reasoned about — and tested — on its own"* | **0** |
| `decodeFilePreview` (`files/logic/file_preview.dart`) | — | *"Pure, so these three judgements are testable without a filesystem"* | **0** |
| `filePathCrumbs` (`files/logic/files_path.dart`) | — | — | **0** |

`resolveSidePanel` **has a test now** (`test/chat/panel_tab_strip_layout_test.dart`) — the prior version of
this table was right that it was the costliest gap, and it has been closed.

**The import subsystem is the new costliest gap, and by a distance.** `chat` is one of the areas the
conventions require tests in; these are two hand-written parsers over **another product's undocumented
file format**, which is precisely the code that breaks silently when the format moves — and every one of
them is already a pure function over a `List<String>`, so the fixtures are the only work. `unsaidTail` is
the second: it carries a documented near-miss (an answer compared untrimmed against a trimmed one showed a
sentence twice), and nothing pins it.

### Observability blind spots

**Only a handful of files** emit `CliCallKind.http` (the network controllers, `grid_overview_provider`,
`member_providers`, `network_models_provider`, `playground/chat_sender`, `skills/skill_generator`). So these
**don't** show in the Debug tab or `app_https-*.log`:

- all of `ConnectorGatewayClient` (the OAuth broker — only `appLogProvider`)
- `ModelCatalogClient` — **logged nowhere**
- **`GET /relay/v1/usage`** (**new, 08/17**) — `TurnModelUsage` calls the relay client directly with no
  `commandLog.begin`, unlike `gridOverviewProvider` right beside it. It fires every 5s per open turn and
  swallows every error into `null`, so a caption that never fills has **no trace anywhere** — the one case
  where a blind spot and a silent failure land on the same call
- `SmitheryRegistryClient`
- `FeedbackClient`
- `McpProxy` / `RestInvoker` — **the agent's real tool calls**
- all HTTP fired by `claude`/`codex`/`hermes` themselves

> When a user reports "the connector doesn't work" or "the agent's tool call failed", **the on-disk HTTP
> transcript holds nothing.** You debug via `appLog`.

### Current measurements (2026-08-18, `main`)

- `lib/`: **845 Dart files, ~160,200 lines, 29 feature domains** — the panel work merged in and `prompts/`
  was deleted, so the domain count fell by one while ~6,000 lines arrived.
- **`TODO` in `lib/`: 37 total, of which 31 are `TODO(BE)`** (awaiting the backend).
- **`AppTheme.watch`: 600 call sites.**
- `test/`: **188 files, 2,204 tests, all passing**, 26s at `--concurrency=12` (2026-08-18).
- Largest domains by line count: `chat` 18,091 (70 files) · `agents` 15,805 (80) · `connectors` 11,249 (33)
  · `network` 10,287 (43) · `review` 7,216 (45) · `code` 6,489 (46) · `playground` 6,294 (34).
- Gateway connectors (measured earlier, re-measure before quoting): ~12 rows, mostly `auth_type: app`, many
  with a `mcp_url`, many returning `description: ""` (which is why `connector_blurb_fallback.dart` exists).

| | 06/08 | 10/08 | 12/08 | 17/08 `device` | 18/08 `main` |
|---|---|---|---|---|---|
| Dart files in `lib/` | 558 | 668 | 775 | 821 | **845** |
| Lines | ~105,000 | ~120,900 | ~140,300 | ~154,300 | **~160,200** |
| Feature domains | 23 | 26 | 29 | 30 | **29** |
| `AppTheme.watch` | 399 | 486 | ~540 | 587 | **600** |
| Test files | — | — | 172 | 181 | **188** |
| Tests passing | — | — | 1599 | 2004 | **2204** |

> Re-measure before quoting any number here. This table has gone stale repeatedly.

### Standing debt: a consent surface that was deleted, not decided

The commented-out `AttachLogsField` lines in `feedback_dialog.dart` are gone (as conventions §3 requires),
but **the behaviour they hid is still there**:

- `_attachLogs` is initialised `true` and **written by nothing**, so `_send()` always builds and uploads the
  log bundle. Its own doc comment still says the switch is *shown*, and *readable in full before the send,
  because these logs carry file paths and command output, not just a version string* — none of which is
  true any more. Sending someone's shell output is not a default to leave invisible.
- It is the repo's **only** analyzer issue (§12): a `final` the linter can see is never reassigned. The lint
  is the last visible trace of the decision.
- Two honest endings, and the code is at neither: bring the switch back, or drop the field and **say plainly
  in the dialog that the logs are attached**. Deleting the control while keeping the upload is the one shape
  that is neither.

### Contradiction: what a `private-domain` grid actually admits

Two files in `network/` state **opposite rules**, and both are user-facing:

| | Says |
|---|---|
| `share_grid_dialog.dart` (`_accessSummary`) | *"Only the people listed above can use this grid."* — with a doc comment arguing the earlier "anyone with an @domain email" wording was an invention |
| `members_tab.dart` + `ManagedNetworkMember.isDomainMember` | a `source: 'domain'` member is here *"by their address alone"*, so **Remove is hidden**: *"this grid admits everyone at that domain … they'd still be here on the next refresh"* |

If the second is right, people who are not "listed above" can use the grid, and the dialog tells an owner
their grid is closed when it is not — the honest-labels failure §5 of the conventions calls a bug rather
than a wording problem. If the first is right, the Members tab is hiding a Remove button that would work.
**One of the two has to be wrong; the control plane's `source` field is the thing to check.**

### Measured dead code (re-checked 2026-08-18)

Still dead, every one re-grepped on 2026-08-18: `overlord/**` (**20 files, 1,417 lines**, and **0
references from outside the folder**) · `models/presentation/{download_row,manager_search_field}.dart` · `catalogModelsProvider`
(only its own definition left) · `shared/layouts/widgets/{hosting_summary,plan_type_pill}.dart` ·
`shared/widgets/{pulse.dart::PulseDot, coming_soon_view.dart, not_yet_badge.dart}` — the last two die **as a
pair**: `coming_soon_view` is the only call site of `NotYetBadge` · `api/models/chat_chunk.dart` ·
`snackBarTheme` in `app_theme.dart` (SnackBar is banned; 0 call sites).

**Cleared since 08/12** — `conversation.dart::groupConversationsByRecency` and
`parsers/{member_entry,denylist_entry}.dart` are gone from the tree, and **`run(timeout:)` is no longer
dead**: `code_cli.dart`, `review_actions.dart` and the new `stt_client.dart` (35s) all pass it.

⚠️ **`skill_generator.dart` changed status** — no longer "0 imports". `new_skill_dialog.dart` now calls
`skillGeneratorProvider`, but the **gate is a constant `final bool _showAiDraft = false`** at the bottom of
that same dialog file. So it *compiles into the bundle, has a call site, and is reachable by no path*. This
kind of dead code is harder to spot than the old kind: grepping "0 imports" **no longer catches it**.

### Design-system debt

| Violation | Count (2026-08-18) | Where |
|---|---|---|
| Bare `IconButton` | **90** sites in 61 files | spread; each needs its own hover (§9) |
| `backgroundColor: AppPalette.windowBg` (dialog sinks in dark) | **9** | login_screen, project_instructions_dialog, create_project_dialog, agent_changes_bar, prompt_dialog, onboarding_page, home_shell… |
| Bare `MenuItemButton` | **3** | agent_picker, approval_picker, task_power_bar — unchanged |
| Bare `CircularProgressIndicator` | **7** | `models/` ×5, `data_sync/` ×2; the one inside `AppSpinner` is the valid one |
| Bare `Card()` (Material) | **1** | node_setup_card.dart |
| `DropdownButtonFormField` / `SnackBar` | **0** ✅ | every match left in `lib/` is a comment explaining why not to use them |

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

**`docs/` is five tracked files now** — `.gitignore` keeps `conventions.md`, `style-guide-grid-app.md`,
`architecture.md`, `git-auto-install.md`, `panel-protocol.md` and ignores the rest, and the local-only notes this table used to
list (`OVERVIEW.md`, `design-system.md`, `messages-tab.md`, `features/connectors/*`) **are gone from this
checkout**. Earlier versions of this note pointed at them anyway; those pointers have been removed rather
than left as a trail to nothing.

| File | Wrong where |
|---|---|
| `README.md` | Says Provider/Models gate by role — they gate by `devOnly × build mode`. Points at `docs/` files that **don't exist** |
| This file, §7.10 | The four `models/` regressions are quoted from the 08/12 read and **have not been re-verified since** — treat them as "probably still true", not as measured |
| This file, §§7.3–7.29 | Re-read on 08/17 and only spot-checked on 08/18. The 08/18 pass covered what changed: the header, §§2–4, §6, §7.1, §7.2, §7.17, §7.30, and §§8–13 |
| Anything quoting a count | Every measured number here carries its date. A number without one is older than it looks |

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
- **The Code half's "publish on completion" watch is client-side** (§7.29) — the durable place for it is the
  relay
- **`GET /relay/v1/usage` carries no chat id**, so "which models served this turn" is correlated by time
  window and two turns at once on the same grid blend (§4.2). A per-turn tag would fix it properly
- **Most grids' masters predate `/usage`** and answer 404 — the caption is empty until the fleet rolls
- **`ManagedNetworkMember.source`** — the control plane needs to say what `domain` membership actually
  admits, so the two contradictory readings in the app (see above) can be settled
- ~~`grid stt transcribe` is not in `autonomous-grid`~~ — **it is, since 2026-08-17.** `cli/stt.py` +
  `cli/parser.py:_add_stt` post to `{api_url}/v1/audio/transcriptions`, which the production control
  plane already serves (verified end to end that day: a 16 kHz clip returned
  `{"success":true,"data":{"transcript":"","lang":"en"}}`). The argv matches this app's exactly, and
  without `--json` stdout **is** the bare transcript. **Both halves of that path were missing on
  2026-08-16 and both landed on 2026-08-17** — the CLI verb and `grid_networks/transcription.py`; a
  stale checkout of either reads as "voice is broken". `pull` all three repos before believing it
- ⚠️ **`grid project …` / `grid task …` are on `origin/feat/distributed-tasks`, unmerged** — the real
  reason the Code half is `devOnly`, alongside the relay's missing projects plane

---

## Related documents

The four tracked docs — everything else under `docs/` is local working notes and is gitignored, so a fresh
clone has only these:

- [`docs/conventions.md`](conventions.md) — architecture, Riverpod rules, Dart style, copy rules, testing policy
- [`docs/style-guide-grid-app.md`](style-guide-grid-app.md) — **the canonical UI spec**, read before styling anything
- [`docs/git-auto-install.md`](git-auto-install.md) — Git probe/download/adopt detail (§4.6, §7.25)
- [`docs/panel-protocol.md`](panel-protocol.md) — **normative** wire protocol for the Grid Panel (§4.7,
  §7.30). Tracked since 2026-08-13, and now the only place the app and the device agree
- this file
- [`scripts/README.md`](../scripts/README.md) — sidecar bundling, signing, packaging

Outside this repo:

- [`../../CONTEXT.md`](../../CONTEXT.md) — **the four repos beside this one and how they meet**: which
  `grid` is which (there are two, sharing no code), every hand-duplicated seam, and what is currently out
  of step — notably that `grid stt transcribe` and `grid project`/`grid task` are **not** on
  `autonomous-grid`'s `main`
