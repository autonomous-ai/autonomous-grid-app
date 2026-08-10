# Grid Desktop App — Kiến trúc, Domain & Feature

> Tài liệu kiến trúc đầy đủ, dựng từ việc đọc toàn bộ `lib/` (**668 file Dart, ~120.900 dòng, 26 feature domain**).
> Cập nhật: **2026-08-10** · Nhánh `main` · Version `0.2.0+1`
>
> Bản 06/08 đo **558 file / 105.000 dòng / 23 domain**. Chênh lệch nằm gần như trọn vẹn ở **một tính năng
> duy nhất**: hệ **panel quanh hội thoại** và ba bề mặt làm việc mở trong đó — `review/` (44 file),
> `files/` (13), `terminal/` (7). Xem §7.22–§7.24, và §3 cho trục điều hướng **thứ hai** mà chúng sinh ra.
>
> Thay thế `docs/OVERVIEW.md` (viết 2026-07-14 — trước khi `prompts`, `appearance`, `auto_router`,
> `connectors`, `skills` tồn tại và trước khi `agents/` phình từ vài file lên 71 file).
> OVERVIEW.md vẫn đúng ở phần build/release và mô tả CLI seam; phần feature thì đã lạc hậu.

---

## Mục lục

1. [App này làm gì](#1-app-này-làm-gì)
2. [Kiến trúc tổng thể — ba mặt phẳng](#2-kiến-trúc-tổng-thể--ba-mặt-phẳng)
3. [Bản đồ điều hướng — toàn bộ màn hình](#3-bản-đồ-điều-hướng--toàn-bộ-màn-hình)
4. [Xương sống hạ tầng](#4-xương-sống-hạ-tầng)
5. [Bản đồ dữ liệu trên đĩa](#5-bản-đồ-dữ-liệu-trên-đĩa)
6. [Luồng khởi động](#6-luồng-khởi-động)
7. [Chi tiết từng domain](#7-chi-tiết-từng-domain)
8. [Luồng xuyên suốt: một lượt chat end-to-end](#8-luồng-xuyên-suốt-một-lượt-chat-end-to-end)
9. [Design system](#9-design-system)
10. [Trạng thái hoàn thiện](#10-trạng-thái-hoàn-thiện)
11. [Invariant quan trọng nhất](#11-invariant-quan-trọng-nhất)
12. [Chạy, build, release](#12-chạy-build-release)
13. [Nợ kỹ thuật](#13-nợ-kỹ-thuật)

---

## 1. App này làm gì

**Grid** là ứng dụng desktop Flutter (macOS / Windows / Linux) đóng vai trò **GUI cho một mạng AI ngang hàng**
cùng tên. Nhưng mô tả đó chỉ còn đúng một nửa: tính đến hôm nay, phần lớn khối lượng code nằm ở
**một trợ lý AI có công cụ chạy ngay trên máy người dùng**.

App cho phép, từ một cửa sổ:

| Nhóm | Việc làm được |
|---|---|
| **Trợ lý AI** | Chat với agent chạy local (Hermes / Codex / Claude Code) — agent đọc/ghi file, chạy lệnh, duyệt web, lái browser thật, giữ session dài |
| **Mở rộng agent** | Cài **skill** (thư mục hướng dẫn), **plugin** (tool backend), **connector** (OAuth vào Gmail/Slack/Notion/… qua MCP) |
| **Tự động hoá** | **Scheduled task** chạy theo cron; kết quả tự rơi vào tab Chat; **goal** để một chat tự chạy nhiều lượt; **Messages** để nhắn tin cho máy này qua Telegram/Discord/Slack |
| **Grid (mạng)** | Tạo / tham gia grid, quản lý thành viên, xem sức mạnh grid (VRAM, node, tok/s), auto-router chọn model |
| **Đóng góp máy** | Chạy provider node: `llama.cpp` local, server ngoài (Ollama/LM Studio), hoặc API engine (OpenAI key / seat Claude Code / seat Codex CLI) |
| **Model** | Duyệt catalog gợi ý theo phần cứng, tải GGUF, phục vụ, đặt context length |
| **Playground** | Chat / sinh ảnh / sinh video OpenAI-compatible stream thẳng từ relay |
| **Projects** | Một project = một thư mục agent được phép đọc, kèm rules + memory ghép vào lượt đầu |
| **Làm việc cạnh chat** | Hai **panel** quanh hội thoại, mỗi cái nhiều tab: **Review** (diff của project, stage/commit/push, comment từng dòng), **Terminal** (shell thật qua pty), **Files** (duyệt & đọc file project). Nội dung của chúng đi ngược vào composer: gắn terminal, gắn file, gắn đoạn bôi đen |

### Bản chất

> **App là lớp vỏ GUI quanh CLI `grid` (Python) + trình điều khiển cho ba agent runtime bên ngoài.**
> CLI sở hữu lifecycle của grid; `~/.grid` là nguồn chân lý. App **không** cache trạng thái riêng —
> chạy CLI từ terminal thì app tự vẽ lại.

Điểm khác biệt lớn nhất so với tài liệu cũ: README và `OVERVIEW.md` mô tả **hai** mặt phẳng
(control = subprocess `grid`, data = HTTP relay). Thực tế hôm nay có **ba** — mặt phẳng thứ ba là
**agent runtime**, và nó lớn hơn cả hai cái kia cộng lại.

---

## 2. Kiến trúc tổng thể — ba mặt phẳng

```
┌────────────────────── Grid Desktop App (Flutter + Riverpod) ───────────────────────┐
│                                                                                     │
│  ┌── CONTROL PLANE ───────┐  ┌── DATA PLANE ────────┐  ┌── AGENT PLANE ──────────┐ │
│  │ GridCliService         │  │ RelayApiClient       │  │ ClaudeExecService       │ │
│  │  (3 method: run/       │  │ ConnectorGateway…    │  │ CodexExecService        │ │
│  │   start/pull)          │  │ ManagedNetworkClient │  │ HermesAcpService        │ │
│  │ subprocess `grid …`    │  │ ModelCatalogClient   │  │ subprocess + stdio      │ │
│  │ auth · network ·       │  │ SmitheryRegistry…    │  │ stream-json / exec      │ │
│  │ provider · models ·    │  │ HTTP + SSE           │  │ --json / ACP JSON-RPC   │ │
│  │ router                 │  │                      │  │                         │ │
│  └───────────┬────────────┘  └──────────┬───────────┘  └───────────┬─────────────┘ │
│              │                          │                          │               │
│              │              ┌───────────┴───────────┐              │               │
│              │              │ ConnectorBridge       │◄─────────────┘               │
│              │              │ HttpServer loopback   │  agent gọi tool qua          │
│              │              │ /c/<connector>/mcp    │  127.0.0.1:<port>            │
│              │              │ MCP proxy + REST→MCP  │                              │
│              │              └───────────┬───────────┘                              │
└──────────────┼──────────────────────────┼──────────────────────────────────────────┘
               ▼                          ▼                          ▼
   ┌───────────────────┐   ┌──────────────────────┐   ┌──────────────────────────┐
   │  grid (Python)    │   │ relay của grid       │   │ hermes · codex · claude  │
   │  daemonize, PID   │   │ api-grid.autonomous  │   │ (binary trên máy)        │
   │                   │   │ Smithery, provider   │   │ + Chrome (CDP 9222)      │
   └─────────┬─────────┘   │ MCP servers          │   └───────────┬──────────────┘
             │             └──────────────────────┘               │
             │ đọc/ghi                                            │ đọc config
             ▼                                                    ▼
   ┌──── ~/.grid  (NGUỒN CHÂN LÝ) ────┐        ┌─── ~/.hermes · ~/.codex · ~/.claude ───┐
   │ credentials.toml · state.json    │        │ config.yaml · config.toml · .claude.json│
   │ networks/<id>/ · models/*.gguf   │        │ skills/ · mcp-tokens/ · cron/           │
   │ run/engines/ · outputs/ · logs/  │        │ (app GHI vào đây — projection)          │
   │ app/* (app-owned) · connectors/  │        └─────────────────────────────────────────┘
   │ skills/ · bin/ · tools/          │
   └──────────────────────────────────┘
```

### Ba invariant gốc (vẫn đúng)

1. **Control plane = subprocess.** Mọi lệnh vòng đời grid chạy qua `grid …`. App không tự quản process.
2. **Data plane = HTTP trực tiếp.** Chat/media stream qua relay (`{lan_signaling_url}/relay/v1/…`).
3. **`~/.grid` là nguồn chân lý.** App chạy lệnh rồi **đọc lại đĩa**, không parse stdout khi thành công.

### Invariant thứ tư (do agent plane sinh ra)

4. **Config của agent là *projection*, không phải nguồn.** Master store là `~/.grid/connectors/tokens.json`
   và `~/.grid/skills/`. App chiếu (project) chúng vào `~/.hermes/`, `~/.codex/`, `~/.claude*`.
   Xoá entry trong config agent mà không xoá ở master store là vô nghĩa — lần project kế tiếp ghi lại.

### Mặt phẳng thứ tư — **local tooling** (mới 08/2026)

Panel quanh chat sinh ra một loại subprocess **không phải `grid`, cũng không phải agent**: `git` và một
**login shell chạy trong pty**. Cả hai đi qua seam riêng ở `infrastructure/cli/`, không dùng `GridCliService`:

| | `git` | shell |
|---|---|---|
| Seam | `GitRepoService` (folder là repo?) + `GitRunner` (argv tuỳ ý) | `Pty.start` (`flutter_pty`) |
| Resolve binary | `probeGit()` — **`~/.grid/tools/git` của app trước, rồi máy** | `resolveShell()` — `$SHELL` của user |
| Argv dựng ở đâu | **hàm thuần** `review_argv.dart`, có test | user gõ |
| Ai spawn | `infrastructure/` | ⚠️ `features/terminal/logic/terminal_session.dart` — **feature tự spawn process** |

> ⚠️ **`GitRunner.run()` nhận argv tuỳ ý.** Khác `GridCliService` (đúng 3 method, catalog argv đóng),
> đây là cửa mở: thứ giữ nó an toàn không phải type mà là **kỷ luật** — mọi argv nằm trong
> `review_argv.dart` dưới dạng hàm thuần có test, không chỗ nào khác được ráp argv tại call site.
>
> ⚠️ **`git` chạy với `GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND='ssh -o BatchMode=yes'`.** App không có
> terminal, nên một `git push` hỏi mật khẩu sẽ treo tới hết timeout mà **không ai gõ được gì**. Tắt prompt
> là thứ khiến màn hình nói được "sign in from Terminal" thay vì quay vòng. Credential helper của máy
> **vẫn chạy** — chỉ chặn nhánh interactive.

### Phân lớp code

```
lib/
├── main.dart              # boot sequence — thứ tự là hợp đồng
├── app/                   # MaterialApp, RootView (router 5 nhánh), single-instance, window lifecycle
├── core/                  # helper thuần: GridPaths, AppEnvironment, host_arch, composer_text
├── infrastructure/        # xương sống — KHÔNG business logic
│   ├── cli/               # GridCliService + 3 agent runtime + Chrome bridge + git seam + parsers
│   ├── api/               # 5 HTTP client + DTO
│   ├── mcp/               # ConnectorBridge, McpProxy, RestInvoker
│   ├── state/             # store đọc/ghi ~/.grid
│   ├── platform/          # clipboard, notification, PDF, font, window focus
│   └── logging/           # 4 sink ghi ~/.grid/logs + ErrorBurstFilter
├── features/              # 26 domain, mỗi cái logic/ + presentation/
└── shared/                # theme (design system), widgets, layouts (shell/sidebar/settings),
                           # code/ (syntax highlight), markdown/ (code block + stylesheet)
```

Quy tắc `presentation → logic → infrastructure`, không bao giờ ngược. **Có 6 chỗ vi phạm thật**
(xem §13).

---

## 3. Bản đồ điều hướng — toàn bộ màn hình

`ShellSection` (`lib/shared/layouts/shell_state.dart:17`) có **15 giá trị**. `section_view.dart:35`
là **bảng ánh xạ duy nhất** `ShellSection → Widget`.

| Section | Widget | Ở đâu | devOnly |
|---|---|---|---|
| `chat` | `ChatPane` | Mặc định của app; sidebar "New chat", tray, notification, ⌘K | |
| `scheduled` | `ScheduledView` | Sidebar row | |
| `agents` | `AgentsView` | Sidebar row | |
| `projects` | `ProjectsView` | Header "Projects" trong sidebar, ⌘K | |
| `skills` | `SkillsView` | Settings ▸ Customize | |
| `connectors` | `ConnectorsView` | Settings ▸ Customize | |
| `plugins` | `PluginsView` | Settings ▸ Customize | ✅ |
| `git` | `GitView` | Settings ▸ Coding | |
| `engines` | `ProviderView` | Settings ▸ Personal (**mặc định của Settings**) | |
| `appearance` | `AppearanceView` | Settings ▸ Personal | |
| `guide` | `HowToUseView` | Settings ▸ Personal | |
| `archived` | `ArchivedChatsView` | Settings ▸ Archived | |
| `messages` | `MessagesView` | Settings ▸ Integrations | ✅ |
| `grids` | `NetworksPane` | Settings ▸ Developer | ✅ |
| `debug` | `DebugView` | Settings ▸ Developer | ✅ |

**Sidebar trái (284px)** chỉ có: brand + ⌘K · **New chat** · **Scheduled** · **Agents** ·
`ChatHistoryList` (Projects → chat con → "Chats" rời, phân trang 5 dòng/lần) · account pill.

**Settings pane** (thay cả shell, không có top bar): 6 group — Personal / Customize / **Coding** /
Integrations / Developer / Archived. Release build còn **4 group / 7 row** (group rỗng tự biến mất).

> **Gate duy nhất là `devOnly × AppEnvironment.isDeveloperMode` (= `!kReleaseMode`)** — tức theo
> **build mode**, KHÔNG theo role hay scope của user. Role chỉ ảnh hưởng nội dung *bên trong* màn hình
> (`SharingLockedView`, nút Delete/Rename chỉ owner). README nói "Provider và Models chỉ hiện cho role
> quản lý được" — điều đó **không còn đúng**.

**Màn hình không nằm trong shell:** `PreflightScreen`, `LoginScreen`, `InstallerScreen`,
`OnboardingChoiceScreen` (4 màn full-screen do `RootView` chọn).

**Màn hình unreachable:** `OverlordView` và cả `features/overlord/` (**1.417 dòng**, không có
`ShellSection`, không route, 0 tham chiếu).

### Trục thứ hai: **panel** — điều hướng KHÔNG đi qua `ShellSection`

Từ 08/2026 tab Chat có hai panel bọc quanh hội thoại, mỗi cái là một **tab strip riêng**. Bề mặt mở
trong đó **không phải** `ShellSection`, không có route, không nằm trong bảng `section_view.dart`:

```
PanelHost.preview   bên phải hội thoại      ┐
PanelHost.bottom    dưới hội thoại          ┘ hai panel, hai bộ tab hoàn toàn tách biệt

PanelFeature.review    ⌃⇧G   Review   ┐
PanelFeature.terminal        Terminal │ bảng ánh xạ: chat/presentation/panel_feature_view.dart
PanelFeature.files     ⌘P    Files    ┘
```

- **`panelTabsProvider` là `family` theo `PanelHost`** — mở terminal cạnh chat không được đụng tới cái
  đang mở dưới chat. Hai panel là hai *nơi làm việc*, như hai cửa sổ của cùng một app.
- **`open()` luôn tạo tab mới; `reveal()` mới là "cho tôi xem cái này".** Phím tắt dùng `reveal` (bấm
  ⌃⇧G ba lần phải ra một Review, không phải ba), menu "+" và launcher dùng `open` (user chọn dòng đó
  nghĩa là "thêm một cái nữa").
- **Tab đã mở ở lại trong cây widget.** Đó là thứ giữ scroll, thư mục đang mở và ô gõ dở qua mỗi lần
  đổi tab. Hai thứ thoát khỏi cơ chế đó và phải được báo bằng `PanelTabVisible`: **popover trong
  overlay** (nổi trên mọi thứ, đổi tab sẽ để nó lơ lửng trên bề mặt chẳng liên quan) và **việc không
  nên chạy khi không ai nhìn**.
- **`shortcut` trong `PanelFeature` là *nhãn*, chưa phải binding** — chỉ `⌃⇧G` có listener thật
  (`home_shell.dart:_openReview`, và nó `select(ShellSection.chat)` trước, vì panel sống trong tab Chat).
- Menu chỉ liệt kê **thứ đã dựng xong**. Browser và Side chat từng có mặt ở đây lúc còn là
  `TODO — <name>`; `e37661d` gỡ đi — *"menu mở ra màn hình trống là câu trả lời tệ hơn menu ngắn"*.

**Ba nút bật/tắt panel nằm ở `AppTopBar`**, theo đúng thứ tự chúng bao quanh chat đọc theo chiều kim
đồng hồ từ mép trái: project rail → bottom → preview. Cùng `PanelToggle` với header của preview panel —
*"phải là cùng một nút, không phải hai cái giống nhau rồi trôi khỏi nhau"*.

---

## 4. Xương sống hạ tầng

### 4.1. Control plane — `GridCliService`

Interface **đúng 3 method** (`lib/infrastructure/cli/grid_cli_service.dart:76`):

```dart
Future<CliResult>       run(List<String> args, {Duration? timeout});
Future<GridProcess>     start(List<String> args, {Map<String,String>? environment});
Stream<DownloadProgress> pull(List<String> args);
```

**Thứ tự resolve binary** (`GridResolver.resolve()`):
1. `configuredPath` (settings — **chưa nối vào UI**) → `GRID_BIN` env
2. Sidecar bundled: macOS `<exe>/../Resources/grid/grid`; Linux/Win `<exe>/grid[.exe]`
   (Mac Intel còn kiểm Mach-O header, **fail open** nếu không parse được)
3. Hệ thống: `~/.local/bin/grid` → `/opt/homebrew/bin/grid` → `/usr/bin/grid` → `$SHELL -lc 'command -v grid'`

Mỗi ứng viên phải tồn tại, có bit execute, và **không phải chính app** (`Grid` khớp `grid` trên
filesystem case-insensitive của macOS).

**Decorator stack** (`infrastructure/providers.dart:29`) — thứ tự là hợp đồng:

```dart
RemoteModeGridCliService(          // prepend --remote (trừ engine/agent/pull)
  LoggingGridCliService(           // ghi CommandLogNotifier → tab Debug
    FileLoggingGridCliService(     // ghi ~/.grid/logs/app_cli-YYYYMMDD.log
      GridCliServiceImpl(path),    // Process.run/start, runInShell: false
      fileLog),
    recorder))
```

`RemoteMode` **ngoài cùng** để tab Debug hiện đúng argv đã chạy (`grid --remote sync`), copy ra
terminal chạy được.

**Env cho process con** (GUI không thừa kế shell env):
`PYTHONUNBUFFERED=1` (thiếu thì URL device-login không thoát buffer) · `PYTHONUTF8=1` +
`PYTHONIOENCODING=utf-8` (Finder launch không có `LANG` → `UnicodeEncodeError`) · `PATH` =
`~/.grid/bin` → `~/.local/bin` → homebrew → system → login-shell PATH → parent PATH ·
`LANG` fallback `en_US.UTF-8`.

#### Catalog `grid …` argv đầy đủ

**Qua `run()`**

| Argv thật | Call site | Parse gì |
|---|---|---|
| `grid --remote --version` | `preflight_service.dart:19` | exit code gate app; `isSupportedGridVersion` ≥ **0.2.0** |
| `grid --remote sync` | 7 chỗ | chỉ `ok` / `sessionExpired` |
| `grid --remote logout` | `auth_controller.dart:131` | — |
| `grid --remote use <id>` | create/rename network | — |
| `grid --remote members add <id> <email> --role provider` | `enable_provider_controller.dart:66` | dòng cuối làm log |
| `grid --remote leave <grid>` | `provider_run_controller.dart:624` | — (**cố ý không `--engine`**) |
| `grid --remote leave <grid> --engine <selector>` | `:520` | sự thật đọc lại từ đĩa |
| `grid --remote catalog` | `models_providers.dart:53`, `model_catalog.dart:37` | **hai parser khác nhau** trên cùng output |
| `grid --remote catalog --api <kind> --json` | `api_engine_catalog.dart:209` | `models[]` + `last_verified` |
| `grid --remote ctx --json <model>` | `models_providers.dart:40` | `context_length` |
| `grid --remote device-info --json` | `suggested_catalog.dart:17` | JSON nguyên khối, app không diễn giải |
| `grid --remote rm <file> --yes` | `model_delete_controller.dart:63` | `--yes` bắt buộc (stdin không interactive) |
| `grid engine status` | `media_status.dart:55` | `Installed:`/`Running:`/`Bundle X/Y` |
| `grid --remote router enable\|disable\|set-advisors\|status\|models … --json` | `auto_router_controller.dart` | **chỗ duy nhất parse stdout thay vì đọc `~/.grid`** |

**Qua `start()`**

| Argv thật | Call site |
|---|---|
| `grid --remote login --no-browser` | `auth_controller.dart:49` — parse URL + `Code:` giữa stream, timeout 5 phút |
| `grid engine install llama.cpp` \| `comfyui` | `engine_setup_controller.dart:73`, `node_setup_plan.dart` |
| `grid --remote join <grid> --serve <gguf> --endpoint-port <free> [--advertise-as] [--ctx-size] --name <node>` | `provider_run_controller.dart:247` |
| `grid --remote join <grid> --at <url> -m <model> --ctx-size 200000 --name <node>` | `:276` |
| `grid --remote join <grid> --api <kind> [-m …] --name <node>` + env `{KIND_API_KEY}` | `:322` — **key không bao giờ vào argv** |

**Qua `pull()`**: `grid pull <spec>` · `grid engine pull <bundle>`

### 4.2. Data plane — HTTP client

| Client | Base URL | Endpoint |
|---|---|---|
| `RelayApiClient` | `{lanSignalingUrl}/relay/v1` | `GET /models`, `GET /grid/overview` |
| Chat/media (playground) | như trên | `POST /chat/completions`, `/responses`, `/media/image/generate`, `/media/image/edit`, `/media/video/i2v` |
| `ManagedNetworkClient` | `api-grid.autonomous.ai` | `POST/GET/DELETE /v1/grid/managed-networks[/{id}/members]`, `PATCH /v1/grid/networks/{id}` |
| `ConnectorGatewayClient` | như trên | `GET /v1/grid/connectors`, `POST …/start`, `/poll`, `/refresh`, `/disconnect` |
| `ModelCatalogClient` | như trên | `POST /v1/grid/catalog` (suggest + list), `GET /v1/grid/catalog/{repo_id}` |
| `SmitheryRegistryClient` | `api.smithery.ai` | `GET /servers?q=… is:remote` — **không gửi credential** |

- `relayBaseUrl` derive **tại client**: `'$lanSignalingUrl/relay/v1'`, `relayApiKey = accessToken`.
- Auth: relay dùng **access token của grid**; control plane dùng **session_token** trong `credentials.toml`.
- Timeout **không đồng nhất**: relay `/models` 2/3/4s, `/grid/overview` 3/4/6s, gateway 10+20s,
  managed-network/catalog 10+30s, `RestInvoker` 30s, `McpProxy` 60s.
- **Chỉ relay + managed-network + skill generator được ghi `CliCallKind.http`.** `ModelCatalogClient`,
  `ConnectorGatewayClient`, `SmitheryRegistryClient`, `McpProxy`, `RestInvoker` **không** xuất hiện
  trong tab Debug lẫn `app_https-*.log`.

### 4.3. Agent plane — ba runtime

| | **Hermes** | **Codex** | **Claude Code** |
|---|---|---|---|
| Cài | `uv tool install --force --python 3.13 'hermes-agent[acp,mcp]'` | tải GitHub release + verify SHA-256 | `curl claude.ai/install.sh \| bash` |
| Lệnh | `hermes acp` (1 arg) | `codex exec [resume] --json --skip-git-repo-check -c …` | `claude -p --output-format stream-json --include-partial-messages --verbose …` |
| Protocol | **ACP JSON-RPC over stdio**, session dài | `--json` event stream, 1 process/lượt | `stream-json` JSONL, 1 process/lượt |
| Model đi qua | `~/.hermes/config.yaml` (ACP không có flag model) | 7 override `-c model_providers.grid-app.*` | env `ANTHROPIC_BASE_URL` + `ANTHROPIC_*` |
| API key | config.yaml + `.env` | env `GRID_APP_API_KEY` | env `ANTHROPIC_AUTH_TOKEN`/`API_KEY` |
| Approval | ✅ **có kênh ACP thật** | ❌ `sandbox_mode="danger-full-access"` | ❌ `--permission-mode bypassPermissions` |
| Message event | **delta** (cộng dồn) | **toàn văn** (thay) | **toàn văn** (thay) |
| MCP | `mcp_servers:` trong config.yaml | `~/.codex/config.toml` | `--mcp-config <file> --strict-mcp-config` |
| Resume | session sống trong process | `exec resume <threadId>` | `--resume <sessionId>` |
| Riêng | cron, gateway messaging, plugin | — | browser lane (extension / CDP) |

> ⚠️ **KHÔNG tồn tại type tên `AgentEvent`.** `infrastructure/cli/agent_event.dart` chỉ là **từ vựng chung**
> (`AgentActivity`, `AgentPlanEntry`, `AgentPermission`, `AgentApprovalMode`, `AgentDetailMode`, `WebSource`).
> Ba runtime giữ **ba sealed family hoàn toàn tách biệt**: `HermesAcpEvent` (7 nhánh),
> `CodexExecEvent` (7 nhánh), `ClaudeExecEvent` (9 nhánh). Chúng chỉ gặp nhau ở **`ChatSendUpdate`**.
>
> Hệ quả thực tế: thêm một khái niệm mới cho mọi agent (ví dụ "agent xin xác nhận") = sửa 3 sealed family
> + 3 sender + 3 parser, và **không có compile error nào nhắc** nếu quên một cái. Ba khác biệt ngữ nghĩa
> đã tồn tại mà **không type nào ghi lại**: message là delta vs toàn văn; chỉ Hermes có permission;
> chỉ Hermes có session dài hạn.

**Điểm hội tụ thật sự** là `ChatSendUpdate` (sealed 5 nhánh, `playground/logic/chat_sender.dart:23`) —
**cả 4 nhánh gửi tin** (relay + 3 agent) đều đổ về đây. `ChatSender` là interface **1 method, 11 tham số**,
nhưng **5/11 tham số bị ít nhất một impl cố ý bỏ qua** (`workdir`/`instructions`/`planFirst`/`approval`/
`conversationId` với relay; `approval` với Codex và Claude) — interface **rộng hơn hợp đồng thật**.

**Bookkeeping session:** `AgentSessionSlots` key `networkId|model|conversationId|workdir`, LRU 5.
Hermes **không** dùng nó (slot giữ một process sống, evict phải `close()`) — `HermesChatSender` có LRU riêng.

**`slot.seen++` chỉ khi turn thành công** — turn fail không append gì, đếm nhầm là lượt sau trích lại
lời của chính agent như "context bạn bỏ lỡ".

### 4.4. MCP bridge — connector → agent

`ConnectorBridge` là **một `HttpServer` loopback duy nhất** (`infrastructure/mcp/connector_bridge.dart`),
port nhớ trong `~/.grid/connectors/bridge.json`, phục vụ `POST http://127.0.0.1:<port>/c/<connector>/mcp`.

```
agent gọi tool ──► bridge ──┬─ effectiveTransport == mcp ──► McpProxy.forward
                            │     POST <provider url>, gắn headers credential
                            │     Accept: application/json, text/event-stream  ← BẮT BUỘC cả hai
                            │     unwrap `data:` CUỐI CÙNG của SSE
                            │
                            └─ transport == rest ──► RestInvoker
                                  dựng HTTP từ RestTool template + arguments model điền
                                  kiểm `required` tại đây, không tin model
```

- Bridge đọc token **mỗi call, không cache bao giờ**; tự renew nếu hết hạn (dedupe qua `_refreshing`).
- Credential **ở lại app** — config agent chỉ có URL loopback, không có header.
- ⚠️ **Bridge không xác thực gì cả.** Bất kỳ process local nào cũng POST được và tiêu credential.
  Rào duy nhất là bind loopback-only.

### 4.5. Logging — 4 sink trên đĩa

Đều dùng `DailyLogFile`: ghi **đồng bộ + flush** (sống sót force-quit), một file/ngày, prune > 14 ngày.

| File | Nội dung |
|---|---|
| `~/.grid/logs/app-YYYYMMDD.log` | `[ts] LEVEL category message` + stack trace; `FlutterError.onError` route vào đây từ dòng đầu `main()` |
| `~/.grid/logs/app_cli-YYYYMMDD.log` | `[HH:MM:SS] #N $ grid …` / `#N \| out` / `#N ! err` / `#N ← done exit=0 (4s)` |
| `~/.grid/logs/app_https-YYYYMMDD.log` | `#N → POST https://…` / `#N ← ok status=200` |
| `~/.grid/logs/app_node_setup-YYYYMMDD.log` | plan đánh số + `-- Step i/n --` |

**Bảo mật log — hai invariant:** chỉ **tên** biến env đi vào log (`envKeys`), header `Authorization`
**không bao giờ** được ghi (chỉ cờ `authorized`). Thêm `--api-key` vào argv là rò key vào cả Debug tab
lẫn transcript.

#### `ErrorBurstFilter` — vì sao log lại cần một cái van

`DailyLogFile` ghi **đồng bộ + fsync trên UI isolate**. Một exception ném từ `build`/`paint`/frame
callback **không xảy ra một lần — nó lặp lại mỗi frame**. 06/08 một assertion tooltip trong mouse tracker
lặp **11.406 lần trong 2 phút rưỡi**, ghi **19MB** stack trace giống hệt nhau, và app phải bị kill.

`main.dart:_installErrorHandlers` giờ lọc qua `ErrorBurstFilter` (`window` 30s, khớp theo **dòng đầu**
cắt 200 ký tự, tối đa 256 chữ ký rồi clear sạch). Bản đầu tiên mang chẩn đoán; phần còn lại chỉ cần
được **đếm** — log ghi `[+3000 identical since the last copy]`.

> `platformDispatcher.onError` khoá theo **chính error**, không theo câu `'Uncaught error'` đứng trước nó
> — mọi uncaught error dùng chung câu đó, và một lỗi lặp không được phép bịt miệng lỗi kế tiếp.

### 4.6. Local tooling — `git` + pty

Xem §2 cho vị trí của mặt phẳng này. Chi tiết:

**`probeGit()` — thứ tự và một cái bẫy chỉ có trên macOS**

1. `~/.grid/tools/git` (bản app tự tải) → 2. Git của máy.

> ⚠️ **Trên macOS tuyệt đối không được exec `/usr/bin/git`.** File đó **có trên mọi máy Mac** — nó là
> một trong 78 hard link tới cùng một stub `xcode-select`, nên kiểm tra "file tồn tại" chứng minh **con
> số không**. Chạy nó khi chưa có Command Line Tools sẽ **bật hộp thoại cài đặt của Apple** đè lên việc
> user đang làm — tức một *probe* biến thành một *lời mời cài đặt*. Nhánh Mac vì thế resolve developer
> directory bằng `xcode-select -p` (binary khác, không bao giờ prompt) rồi chạy git bên trong theo
> đường tuyệt đối.

`GitStatus` sealed 3 nhánh: `GitReady{path, version, ours}` · `GitMissing` · `GitTooOld` — tách
`GitTooOld` khỏi `GitMissing` để copy nói được *upgrade* thay vì *install*.

**Cài Git — một đường duy nhất.** `BackgroundGitInstaller` (launch, im lặng) và nút ở Settings ▸ Git
**đều đi qua `GitInstallController`**: nó giữ single-flight guard, re-probe và adopt. Hai caller riêng
sẽ đua nhau vào cùng một thư mục đích và để lại cây file nửa vời.

> **Git user đã có luôn thắng.** App chỉ lấp chỗ trống. Git mang theo credential helper, proxy và
> certificate **của user** — thay thế nó sẽ làm hỏng việc clone repo private theo kiểu *trông như bug
> của mình nhưng lại là của họ*.

`gitStatusProvider` là `FutureProvider` **cache suốt đời app** (probe spawn process). Thứ gì cài hoặc
gỡ Git **phải invalidate nó** — đúng như `agentInstalledProvider` với `reprobeAgent`.

**pty** (`flutter_pty` + `xterm`): `resolveShell()` lấy `$SHELL` của user. Ba thứ đã là bug thật:

- `TERM=xterm-256color` + `TERM_PROGRAM=Grid` **phải spread đè lên `Platform.environment`** — app mở từ
  IDE thừa kế `TERM=dumb`, và `dumb` tắt màu, tắt con trỏ, tắt mọi chương trình full-screen
- **`xterm` đếm cột-rồi-hàng, pty đếm hàng-rồi-cột** — truyền thẳng là hoán vị hai số ở mọi lần resize
  (`terminal.onResize = (w, h, _, _) => pty.resize(h, w)`)
- **Kill bằng `SIGHUP`, không phải `SIGTERM`** — đó là thứ đóng cửa sổ terminal gửi đi, nên shell sẽ
  hangup con của nó (một `flutter run` đang chạy) thay vì để chúng ôm một pty không ai đọc.
  Windows chỉ biết `SIGTERM`/`SIGKILL` — xin thứ khác là ném exception

---

## 5. Bản đồ dữ liệu trên đĩa

### `~/.grid` — CLI sở hữu

| Đường dẫn | Ai ghi | Format | Module đọc |
|---|---|---|---|
| `credentials.toml` | CLI | TOML | `sessionProvider` ← `GridHomeStore.readCredentials()` |
| `state.json` | CLI (`grid use`) | JSON | `activeRemoteGridProvider` (`active.remote`) |
| `api_keys.toml` | CLI | TOML | `storedApiKinds()` — chỉ đọc **sự hiện diện** |
| `networks/<id>/config.toml` | CLI | TOML | `readNetworkConfig(id)` |
| `models/*.gguf`, `*.part` | CLI (`grid pull`) | binary | `localModelsProvider`, `downloadingModelsProvider` |
| `outputs/*` | app + CLI | media | `saveMediaOutputs` |
| `run/engines/<gridId>/<engineId>.json` + `.log` | CLI | JSON | `listEngineRuns()` — **scan thư mục, không đoán tên** |
| `logs/*` | app | text | tab Debug "Open logs" |
| `bin/` | app + CLI | binary | `uv`, `llama-server`, `codex`, agent |
| `tools/`, `python/` | `uv` | — | Hermes venv |
| `tools/git/` | app (`GitInstaller`) | binary tree | `probeGit()` — **giải nén nguyên cây**, không chỉ file `git`: thiếu `libexec/git-core` thì `git clone` qua HTTPS chết bằng `'remote-https' is not a git command`. Với tới qua `HostEnvironment.gitEnvironment()` |

### `~/.grid/app` — app sở hữu (CLI không chạm)

| File | Nội dung |
|---|---|
| `chats/<id>.json` | Toàn bộ transcript conversation |
| `chat_prefs.json` | grid, model, approval, detail mode, themeMode, chatAgent, 2 font family + 2 size |
| `projects.json` | `Project{id, name, path, instructions, memory, pinned}` |
| `project_tasks.json` | `{jobId → projectId}` |
| `prompts.json` | Thư viện prompt `/` |
| `onboarding.json` | `{"decision": "local"\|"openai"\|"later"}` |
| `model_context.json` | Context window **học được từ lỗi engine** (relay không quảng cáo) |
| `task_delivery.json`, `task_inbox.json` | Bookkeeping sweep kết quả cron |
| `agent-workspace/` | Workdir mặc định của agent khi chat không thuộc project nào |
| `services/<name>.json` + `.log` | Record `grid-serve` skill để lại |
| `chrome/` | Profile Chrome riêng của bridge (**không đăng nhập gì**) |
| `claude-mcp-config.json` | MCP config ghi lại **mỗi lượt** Claude |

### `~/.grid/connectors` — master store connector

| File | Nội dung | Mode |
|---|---|---|
| `tokens.json` | **Nguồn chân lý** OAuth token | 600 |
| `clients.json` | DCR client đã register, key = **issuer** | 600 |
| `manual.json` | MCP server user tự gõ | 600 |
| `bridge.json` | Port bridge đã nhớ | — |
| `projections/codex.json` | Sidecar marker (Codex nuốt key lạ) | — |

### `~/.grid/skills` — thư viện skill

`user/<slug>/` (user viết) · `public/<slug>/` (từ catalog + Grid built-in).
**Nằm ở thư mục nào chính là authorship** — không có manifest nào phải giữ đồng bộ.

### Thư mục của agent — app GHI vào (projection)

| Đường dẫn | App ghi gì |
|---|---|
| `~/.hermes/config.yaml` | `model.default`, `custom_providers`, `mcp_servers`, `platform_toolsets.cron`, `approvals.*` — qua `YamlEditor`, luôn `.bak` trước |
| `~/.hermes/.env` | Token Telegram/Discord/Slack + allowlist — qua `EnvFile`, luôn `.bak` |
| `~/.hermes/mcp-tokens/<name>.json` | Credential OAuth (RFC 6749 §5.1), chmod 600 |
| `~/.hermes/skills/<slug>/` | Copy skill |
| `~/.hermes/cron/jobs.json`, `output/<jobId>/*.md`, `ticker_heartbeat` | Hermes ghi, app **đọc** |
| `~/.hermes/gateway_state.json` | Hermes ghi, app đọc `platforms.<key>.state` |
| `~/.codex/config.toml` | `mcp_servers` — **re-encode cả file** (mất comment/thứ tự key), `.bak` là lưới an toàn duy nhất |
| `~/.codex/.env` | `GRID_API_KEY` |
| `~/.codex/skills/<slug>/` | Copy skill |
| `~/.claude.json` | `mcpServers` (marker `_grid`) — 72 KB state của user, merge cẩn thận |
| `~/.claude/settings.json` | Chỉ block `env` (từ màn "How to use") |
| `~/.claude/skills/<slug>/` | Copy skill |

---

## 6. Luồng khởi động

### `main.dart` — thứ tự **là hợp đồng**

1. `WidgetsFlutterBinding.ensureInitialized()`
2. **Log trước tiên** — `FileAppLog` + `FlutterError.onError` + `platformDispatcher.onError`
   → crash lúc startup vẫn để lại stack trên đĩa
3. `MediaKit.ensureInitialized()` (libmpv cho video/audio inline)
4. **Single-instance** — `ServerSocket.bind(127.0.0.1:52677)` + liveness probe byte `0x47`.
   Bind fail mà không ai trả lời → **vẫn chạy tiếp** (thà hai instance còn hơn app tự đóng vì port kẹt)
5. `windowManager` + `setPreventClose(true)` (arm `onWindowClose`), 1280×800, min 880×560,
   titlebar hidden trên macOS
6. **Sparkle** — set feed URL (`{arch}` thay bằng `arm64`/`x86_64`), interval 86400s.
   **Cố ý không check ngay** — check launch nằm ở `HomeShell`
7. **Dựng** `SystemDesktopNotifier` — nhưng **KHÔNG xin permission ở đây** (xem cảnh báo dưới)
8. `runApp(ProviderScope(overrides, child: ConnectorRefreshScope › GridSkillsScope › NotificationScope › GridApp))`

> ⚠️ **Bước 7 đã đổi, và lý do là một bug thật.** `ensurePermission()` **không return cho tới khi user
> trả lời hộp thoại của OS**. Cửa sổ đã dựng ở bước 5 nhưng chưa có frame nào được vẽ cho tới `runApp` —
> nên `await` ở đây để lại một **cửa sổ đen không đóng được** suốt thời gian hộp thoại đứng đó (lần mở
> đầu tiên sau mỗi bản update). Giờ notifier được override **vô điều kiện** (`show` tự no-op tới khi nó
> biết câu trả lời), còn việc hỏi dời xuống `HomeShell` sau frame đầu.

Hai scope ngoài cùng nằm **ngoài router** vì token connector và skills là *của agent* — agent trả lời
chat bất kể user có mở màn Connectors/Skills hay không.

### `RootView` — router 5 nhánh

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

- `canProceed == gridAvailable` — `grid --remote --version` exit 0 và version ≥ 0.2.0.
  Version **không parse được thì PASS** (chặn checkout-from-source còn tệ hơn).
- `isLoggedIn` một mình chưa đủ: token chết vẫn nằm trong `credentials.toml` → phải cộng `needsLogin`.
- Gate installer hiện **chỉ là `!hermesInstalled`** — engine và model không còn là điều kiện.
- `routeFor` nhận `GridOverview?` chứ **không** `AsyncValue` — nhận `AsyncValue` là mỗi frame `loading`
  của poll nền → splash → remount top bar → poll lại: 3 round-trip/giây.

### `HomeShell` mount — 7 việc post-frame

1. `BackgroundModelController.startIfNeeded()` — tải model nền (guard chuỗi 7 điều kiện)
2. `BackgroundAgentInstaller.startIfNeeded()` — cài agent còn thiếu, im lặng
3. `BackgroundGitInstaller.startIfNeeded()` — adopt Git của user, hoặc tải bản của app, im lặng
4. `TaskDeliveryController.start()` — `Timer.periodic(30s)` sweep kết quả cron vào chat
5. `_markTaskChatRead(activeId)`
6. `appUpdater.checkInBackground()` — đặt ở đây để prompt Sparkle không đè lên màn download model
7. `desktopNotifier.ensurePermission()` — **cùng hai lý do**: không được rơi vào giữa first-run setup,
   và hỏi ở `main` thì giữ lại frame đầu (cửa sổ đen). Ở đây app đã vẽ xong và lời xin có nghĩa —
   user đang nhìn đúng thứ đang hỏi

**Phím tắt shell:** `⌘K` palette · `⌘,` Settings · **`⌃⇧G` Review** (binding của Codex cho cùng việc;
`select(ShellSection.chat)` **trước**, vì panel sống trong tab Chat — bắn từ Settings sẽ mở thứ user
không nhìn thấy).

### Teardown — phải có **cả hai** đường

- Nút close cửa sổ + tray "Quit" → `onWindowClose()` (nhờ `setPreventClose(true)`)
- **⌘Q / app-menu Quit / OS log-out** → `didRequestAppExit()` — `setPreventClose` **không** phủ đường này

Cả hai gọi `shutdownServing()` (timeout 8s): kill process con, rồi `grid leave` cho mọi grid trong
`{_grid} ∪ listServingGrids()`. Thiếu một trong hai là `llama-server` mồ côi.

Kill cứng không chặn được — engine đó được **adopt lại** ở lần chạy sau qua `reconcile()`.

---

## 7. Chi tiết từng domain

### 7.1. `chat/` — bề mặt hội thoại chính

**Sở hữu:** vòng đời một *cuộc hội thoại đã lưu* — model `Conversation`, persistence
`~/.grid/app/chats/<id>.json`, state gửi/stream/huỷ **theo từng chat** (nhiều chat có thể đang trả lời
cùng lúc), và mọi UI quanh nó.

`ChatSessionsController` (**579 dòng** — `9712fb6` tách nó theo 4 việc nó làm: `chat_sessions_send`
404, `chat_sessions_state` 304, `chat_sessions_goals` 135, `chat_sessions_settle`) là lõi. State:

```dart
conversations: List<Conversation>   // toàn bộ, kể cả archived
activeId, draftProjectId, loading
runningAgentId: String?             // chat đang giữ slot agent DUY NHẤT
phases: Map<String, SendPhase>      // chỉ chứa chat đang bận
errors, awaitingPlanIds, queued: Map<String, List<QueuedTurn>>
```

Getter kép — bản "cho chat đang mở" (`phase`, `sending`) và bản "cho chat bất kỳ" (`phaseFor`,
`sendingFor`) vì sidebar phải đánh dấu chat nền đang chạy.

#### `send()` — 11 bước

1. Trim, bỏ rỗng
2. **Bận thì xếp hàng** → `_enqueue(QueuedTurn)`. Composer **không** bị disable — đó là lý do queue tồn tại
3. Chọn chat đích (`_activeOrNew` tạo id = microsecondsSinceEpoch)
4. Đọc approval **một lần** — turn chạy theo mode lúc bấm Send
5. Quyết định planning turn
6. `buildUserTurn` — ảnh ghi vào `~/.grid/outputs`, file text đã trích lúc attach
7. Đặt tên lần đầu (`deriveConversationTitle`) — chỉ một lần
8. **`_commit()` ghi đĩa TRƯỚC khi gửi** → tin user không bao giờ mất
9. `agentAnswersTurn(modality, hasAttachments, agentInstalled)` — agent chỉ nhận **text, không attachment, và phải cài**
10. **Serialize agent turn**: đúng **một** agent turn tại một thời điểm (`runningAgentId` + `_agentQueue`).
    Turn relay/media chạy song song thoải mái
11. `return done.future` — `await send(...)` đợi turn settle (goal loop dựa vào đây)

#### Feature con

| Feature | Cơ chế |
|---|---|
| **Archive** | `archivedAt` là **timestamp, không bool**. `copyWith` cần cờ `clearArchivedAt`. `_commit` tự unarchive khi user nói chuyện |
| **Pin** | `liveConversations()` đẩy pinned lên trước |
| **Goal** | `ChatGoal{objective, maxTurns=10, maxMinutes=30}`, state machine thuần `advanceGoal`. Reply khớp `^GOAL COMPLETE$` → done. `resumeGoal` cấp **budget mới hoàn toàn** |
| **Plan mode** | approval = `plan` → turn read-only + `withPlanPreamble` → `PlanApproveBar` → "Approve & run" gửi câu duyệt với `planFirst: false` |
| **Queue follow-up** | Gõ tiếp trong lúc agent chạy → hàng đợi có nút X; drain từng cái sau khi turn trước settle |
| **Attachment** | 3 lối vào (nút +, ⌘V, drag-drop). Ảnh cap 4, file cap 5, 25 MB. Trích text: PDF qua PDFKit (chỉ macOS), docx/xlsx/pptx tự parse OOXML, cắt ở 20.000 ký tự |
| **@-mention** | `activeMention(text, cursor)` — `@` phải mở token; menu đọc `workdirEntriesProvider` (một cấp, cắt 60 dòng) |
| **`/`-prompt** | Thư viện prompt; **loại trừ nhau với `@`**, prompts thắng |
| **Minimap** | Rail tick bên trái, chỉ đánh dấu **user turn**, chỉ hiện khi content ≥ 1.5× viewport |
| **Chat từ scheduled task** | id = `task-<jobId>`; `deliverFromAgent` tạo chat nếu chưa có, **không** đổi `activeId` |

#### Panel quanh hội thoại — hình học nằm ở `chat/logic`, nội dung ở feature khác

`chat/` **sở hữu chỗ đứng và kích thước** của panel; nó không biết Review/Terminal/Files là gì (trừ
đúng một file: `panel_feature_view.dart`, bảng ánh xạ).

| File | Sở hữu |
|---|---|
| `logic/panel_tabs.dart` | `PanelHost` (2), `PanelFeature` (3), `PanelTab`, `panelTabsProvider` family |
| `logic/panel_layout.dart` | **Toàn bộ hằng số hình học** + `resolvePanelSizes()` thuần |
| `logic/preview_panel.dart` | mở/đóng + **expanded** (panel chiếm cả pane) |
| `logic/bottom_panel.dart` | mở/đóng panel dưới |
| `logic/composer_context.dart` | terminal nào sẽ đi kèm tin nhắn kế tiếp |
| `shared/widgets/panel_*.dart` | `PanelBody` (toolbar 36px + main + side), `PanelSplitter`, `PanelToggle`, `panelSideWidthProvider`, `PanelTabVisible` |

**`resolvePanelSizes()` là hàm thuần, ngoài `build`** — bốn cái clamp phải nhất quán với nhau, và từ khi
kéo được thì hai trong số đó có nguồn thứ hai. Kéo chỉ là một **yêu cầu**: yêu cầu làm tràn composer
hoặc xoá sạch transcript được đáp lại bằng kích thước gần nhất **không** gây ra điều đó.

**`kChatMinWidth = 440` là số ĐO, không phải số suy luận — và lần đo đầu sai theo hai cách**, đã ship
sọc tràn lên composer thật: harness dựng `ComposerSection` trần trong khi chat view bọc nó trong
`Padding(20,10,20,20)` (thiếu 40px), và thay ba picker bằng một pill co được nhiều hơn `ComposerTrigger`
thật (sàn thật ≈ 58px bất kể nhãn ghi gì). Đo lại: sạch ở 396, tràn ở 392.
**Đo lại trước khi đổi — failure mode là sọc, không phải "trông hơi chật".**

**Override kích thước để `null` khi nghỉ, không phải một con số.** Một mặc định đã lưu sẽ **thôi trả lời
theo bề rộng cửa sổ**, nên panel chỉnh trên màn hình lớn về laptop là sai cứng. Kéo rồi thì dính suốt
phiên — đủ lâu để là một quyết định, không đủ lâu để một cú kéo hỏng sống dai hơn nó.

**Trần mặc định ≠ trần khi kéo.** `kPreviewMaxWidth = 760` / `kBottomMaxHeight = 420` / `kPanelSideMax = 280`
chỉ chặn **share app tự chọn**. Một khi user đã nắm lấy seam thì họ đã nói ra ý mình, và thứ duy nhất
còn phải bảo vệ là sàn của phía bên kia.

**`_clamp` tự viết, không dùng `num.clamp`** — `clamp` assert `low <= high`, nên một pane hẹp hơn cả hai
sàn sẽ **ném exception thay vì xuống cấp**. Ở đây "hết chỗ thì chỗ thắng".

Ba thứ nhỏ, mỗi cái là một bug đã sửa:

- **`PanelSplitter` dùng `dragStartBehavior: DragStartBehavior.down`** — mặc định (`start`) vứt bỏ đoạn
  di chuyển đưa recognizer qua slop, nên seam tụt sau con trỏ vài pixel và **ở lại đó suốt cú kéo**
- **Dải bắt chuột (7px) rộng hơn đường kẻ (1px)** nó vẽ. Đúng thứ khiến nó không thể chỉ là một
  `Divider` bọc `MouseRegion`
- **Tab strip co theo số tab rồi mới scroll** (`kTabMaxWidth` 180 → `kTabMinWidth` 96) — panel hẹp từng
  đẩy nút "+" ra khỏi tầm nhìn ở tab thứ tư, và **một control phải scroll mới tới được là control người
  ta kết luận là không có**

**`previewPanelExpanded` `watch` `previewPanelOpen` trong `build()`** để đóng/mở panel là reset expanded.
Không có dòng đó thì đóng lúc đang expanded để cờ dính lại, và lần mở sau **nuốt trọn hội thoại không
báo trước**.

**Panel cố ý KHÔNG persist và KHÔNG per-chat.** Nó trả lời *"tôi có đang làm việc trong này không"*,
khác project rail (*"tôi có muốn xem card của project này không"* — cái đó thì dính).

#### Nội dung panel đi ngược vào composer

| Đường | Cơ chế | Cap |
|---|---|---|
| Gắn terminal | `attachedTerminalsProvider` **derive** từ panel nào đang mở + tab active là terminal | tối đa 2 (một panel một cái), **không đếm ở đâu cả** |
| Gắn file | `composerFileRequestProvider` ← menu chuột phải "Add to chat" | `kFileTextBudget` |
| Gắn đoạn bôi đen | `composerSnippetProvider` (**queue**, không phải một giá trị) | `kSnippetBudget` 4.000 ký tự × `maxChatSnippets` 8 |
| Nhờ agent review | `composerPrefillProvider` ← Review "Ask the assistant" | — |

> **Terminal được chụp lúc bấm Send, không sớm hơn.** Cái phút giữa lúc mở terminal và lúc hỏi về nó
> thường **chính là** cái phút thứ đang được hỏi xảy ra: một build còn đang chạy lúc chip hiện ra thì đã
> fail lúc tin nhắn đi. Chụp ở Send là thứ khiến attachment đáng có.

- Chip terminal **derive** nên phải có `dismissedTerminalsProvider` — không có gì nhớ cú ✕ thì frame kế
  tiếp dựng lại chip ngay. Dismiss thuộc về **bản nháp**, nên `clear()` chạy ở Send
- Terminal lấy **đuôi** (200 dòng / 8.000 ký tự), **không bao giờ lấy đầu** — thứ khiến người ta gắn
  terminal là thứ vừa xảy ra trong đó. Cắt ký tự cũng cắt từ phía trước, cùng lý do
- Terminal trống trả `null` chứ **không** trả block rỗng — tin nhắn nói "đã gắn" trong khi không gắn gì
  là nói dối
- `ChatContext` nằm **cạnh** text, không **trong** text (như file đính kèm): bubble hiện chip, model đọc
  `promptBlock`. Câu của user chôn dưới 200 dòng build output là phiên bản đã làm transcript không đọc nổi
- Snippet thì **ngược lại — gộp thẳng vào text** (`messageWithSnippets`), vì đó là thứ khiến transcript
  trung thực: lượt của user hiện đúng cái đã hỏi, kể cả phần trích dẫn

#### Cạm bẫy đắt nhất

- `archivedAt` **phải** parse bằng `_parseNullableDate` — `_parseDate` fallback epoch làm mọi chat cũ
  thành "archived 1970" và sidebar trống trơn sau update
- `_restore` phải mở chat **live** đầu tiên, không phải `conversations.first`
- Mọi thứ đọc lịch sử chat dùng `state.live`, **không** `.conversations` — 4 chỗ đã phải sửa
- `_syncModelField` phải **đợi `options` không rỗng** trước khi đánh dấu synced
- `ChatStore.save` là **sync write trên UI thread**, mỗi turn ghi lại toàn bộ file
- ⚠️ `chat_header.dart:36` `_menuSize` tính **4 row + 1 divider** nhưng `_ChatMenuContent` dựng
  **6 row + divider + Delete = 7** → lệch ~108px. **Đang sai.**

### 7.2. `agents/` — lớp trừu tượng agent (71 file, nhiều file nhất)

**Seam duy nhất** giữa feature `chat`/`skills`/`plugins`/`connectors` và ba runtime cụ thể:
không feature nào ngoài `agents/logic/adapters/` được biết tên class `Hermes*`/`Codex*`/`Claude*`.

#### Adapter matrix

| Trục | Hermes | Codex | Claude Code |
|---|---|---|---|
| Probe binary | `hermes_tool.dart` | `codex_tool.dart` | `claude_tool.dart` |
| Chat sender | `hermes_chat_sender.dart` | `codex_chat_sender.dart` | `claude_chat_sender.dart` |
| Extensions | `hermes_extensions.dart` | `codex_extensions.dart` | `claude_extensions.dart` |
| MCP config | YAML | TOML | JSON |
| Connector projection | + `hermes_token_projection` | sidecar marker | in-entry marker |
| Riêng | `hermes_grid_link`, `hermes_skill_scanner`, `hermes_shared_skills` | — | `claude_browser`, `claude_turn_mcp_config` |

#### Ai trả lời một lượt

```
ChatSessionsController.send()
  → agentAnswersTurn(modality, hasAttachments, agentInstalled)
      false → chatSenderProvider (relay HTTP)
      true  → chatAgentSenderProvider
                → activeChatAgentProvider  (resolve, KHÔNG lưu)
                    chatPrefs.chatAgent nếu _canAnswer (installed && agentRunsOnGrid)
                    ngược lại mượn agent đầu tiên clear cả hai bar
                    cuối cùng kChatAgent = hermes
```

Pick của user trong prefs **không bị ghi đè** → đổi grid xong là trả lại.

#### Approval flow — **chỉ Hermes có kênh**

```
ACP permission request
  → decideHermesPermission(toolKind, options, mode)
      toolKind ∈ {read, search, fetch, think}  → allow ngay, không hỏi
      readOnly / plan                          → HermesRefuse
      ask                                      → HermesAskUser
      full                                     → allow_once (KHÔNG BAO GIỜ allow_always)
  → AgentPermissionController.ask(), timeout 55s (Hermes bỏ cuộc ở 60s)
  → AgentPermissionCard pin TRÊN composer (không trong transcript, không scroll mất)
```

> ⚠️ **Codex và Claude Code chạy `danger-full-access` / `bypassPermissions`** — ghi file và chạy lệnh
> **ở bất kỳ đâu trên máy, không hỏi ai**. `claude -p` / `codex exec` là non-interactive và **không có
> kênh approval**. `ApprovalPicker` trong composer hiển thị cho mọi agent nhưng **chỉ chi phối Hermes**.
> Đây là `TODO(BE)` được ghi rõ ở `codex_chat_sender.dart:54` và `claude_chat_sender.dart:55`.

#### Năm skill built-in `grid_*`

| Skill | Script | Làm gì |
|---|---|---|
| `grid-web` | `search.py`, `read.py`, `browse.py` | Tìm & đọc web qua `uv run --with ddgs/trafilatura/playwright`. **Codex và Claude Code trên grid không có web search nào** — tool của họ do vendor API phục vụ |
| `grid-host` | — | "Máy này có gì" — macOS không có `timeout`/`gh`/`rg`. Rút từ 83 lượt Codex ghi lại |
| `grid-serve` | `serve.py` (~540 dòng) | Chạy service sống lâu hơn tool call: launchd → screen → tmux → detached |
| `grid-research` | (dùng script của `grid-web`) | Phương pháp nghiên cứu: nhiều truy vấn, đọc trang thật, mục "Not verified" |
| `grid-chart` | — | Dạy agent format ```` ```chart ```` mà transcript render. Không có nó thì tính năng vẽ chart **vô hình** |

Cài lúc launch qua `GridSkillsScope`, ghi vào **hai** nơi (library + folder agent), **dựng lại chứ không
copy** (card nhúng đường tuyệt đối tới script của chính nó). **Chỉ ghi khi folder chưa tồn tại** →
card đổi lời trong build mới **KHÔNG** tới được agent đã có skill đó.

#### Claude MCP handshake — quirk chính

`claude -p` load **mọi** server trong `~/.claude.json`, handshake song song, và đóng tool list ở thời điểm
nào đó. Đo 2026-08-04 với 27 server: qua 6 lượt, `github` vào list 4 lần, `gmail` 3 lần,
`googledrive` **không lần nào**. Giới hạn về 3 connector của Grid ⇒ **4/4 lần connected, đủ 164 tool**.

- `--strict-mcp-config` mới là nửa làm việc — thiếu nó thì document bị *merge* với `~/.claude.json`
- `--mcp-config <path không tồn tại>` làm chết turn **trước khi tới model** → write hỏng phải trả `null`
  để bỏ **cả hai** flag

#### Browser lane (chỉ Claude)

```
planClaudeBrowser({model, extensionState, cliSupportsChrome, cdpReady})
  extension: model là seat (claude:*) && --chrome có trong --help && extension ready
             → env RỖNG + drop kClaudeRelayEnvKeys (extension từ chối session dùng API key)
  cdp:       có npx + browser → spawn Chrome --remote-debugging-port=9222
             --user-data-dir=~/.grid/app/chrome (profile riêng, KHÔNG đăng nhập gì)
             → MCP entry chrome-devtools = npx chrome-devtools-mcp@latest
  none:      mọi outcome đều log kèm LÝ DO
```

#### Undo file agent đã sửa

`AgentChangesController.record(path, before, after)` — **`before` đầu tiên thắng** (undo trả về bản gốc
pre-agent). `AgentChangesBar` auto-hide 10s, có Review (diff từng file) + Undo all.
Hermes báo path agent gõ nguyên văn (hay có `~/`) → phải `expandHome()`.

### 7.3. `connectors/` — OAuth + MCP integration

**Sở hữu:** catalog để duyệt, **hai** luồng OAuth, kho credential, MCP server user tự nhập, và việc chiếu
mọi thứ đó vào **cả ba** agent để một lần đăng nhập dùng được ở mọi agent.

#### Path B — gateway brokered

```
POST /v1/grid/connectors/start {"connector": "gmail"}
  → {authorize_url, pickup_code, poll_interval, expires_in}
  → _forgetLocally()  (START TRƯỚC, XOÁ SAU — fail thì credential cũ còn nguyên)
  → mở system browser
  → vòng lặp POST /poll {"pickup_code"} mỗi poll_interval
      MỌI kết cục đều HTTP 200; `status` là tín hiệu duy nhất
      pending → tiếp · ready → adopt · failed/expired/consumed → dừng
  → _store(token):  ghi tokens.json → chmod 600 → ĐỌC LẠI XÁC NHẬN → projectTokens()
```

> ⚠️ **`ready` chỉ đến đúng một lần.** Poll lại trả `consumed` **không kèm token**, không có cách lấy lại.
> Vì thế `_store()` ghi đĩa *trước* mọi state change, mọi toast, mọi thứ có thể throw.

#### Path A — DCR self-serve (RFC 7591 + PKCE S256)

```
mcpAuthProbe(mcpUrl):
  1. POST <mcpUrl> body JSON-RPC `initialize` thật (không GET — streamable-HTTP trả 405)
     401/403 → parse WWW-Authenticate · 2xx → anonymous works
  2. resourceMetadata → /.well-known/oauth-protected-resource<path> rồi bản trần
  3. 4 URL metadata: oauth-authorization-server + openid-configuration,
     mỗi cái dạng CHÈN well-known trước path (RFC 8414 §3.1) rồi dạng nối đuôi
     — Stripe/monday.com/GitHub chỉ publish dạng đầu
  → có registration_endpoint → dynamicRegistration, không → preRegistered

connectDirect:
  OAuthLoopbackListener.bind()  — thử 51789..51792 rồi mới để OS cấp
                                  bind CẢ IPv4 và IPv6 cùng port
  oauth.register(...)           — reuse clients.json chỉ khi issuer VÀ redirectUri đều khớp
  PKCE (32 byte Random.secure, SHA-256 tự cài) + state 24 byte
  → browser → loopback callback → so `state` TỰ TAY → exchange
```

#### Projection — `MarkedMapProjection`, ba luật bất khả xâm phạm

1. **Xoá theo tên, không theo phép trừ.** Chỉ `removing` mới xoá. Store rỗng ≠ "xoá hết"
   (30/07: một token `asana` hết hạn làm store rỗng và cuốn theo hai connector đang chạy)
2. **Entry không có marker là của user** — không sửa, không xoá
3. **Không có gì để ghi thì không ghi gì** — tránh churn file user mỗi refresh sweep

Marker có hai hình: `InEntryMarker('_grid')` (Hermes, Claude — cả hai giữ key lạ) và
`SidecarMarker` (Codex — đo 03/08 thấy `[mcp_servers.x._grid]` bị nuốt khi `codex mcp add` chạy cho
server **khác**). Sidecar chỉ chứa **tên**, không bao giờ chứa token.

#### Refresh tự động

Lịch **theo deadline, không phải poll**: lấy min `expiresAt` của token refresh được, trừ head-start 5 phút,
clamp `[1 phút, 1 giờ]`. Không có token refresh được → **không đặt timer**.

> **Thất bại không bao giờ xoá gì** — kể cả 401 — vì `refresh_token` là thứ duy nhất còn cứu được.

#### Cạm bẫy

- `null` ≠ `ConnectorTransport.none`: `null` = gateway không nói gì; `none` = gateway khẳng định
  "grant này không tới đâu cả". Gộp lại sẽ âm thầm unlink mọi token ghi trước khi field tồn tại
- `saveRefreshed` phải **merge chứ không assign** — `/refresh` chỉ trả credential, ghi đè xoá
  `scope`/`account_name`/`mcp_entry`
- `bearerScheme` luôn viết `Bearer` dù provider trả `bearer` — canva/cloudflare/postman trả 401 cho
  chính chữ họ gửi
- PKCE `plain` bị từ chối thẳng dù server có offer
- `isManualAuthType` drop mọi row `auth_type: "pat"` ngay tại parse boundary — connector chưa có OAuth ở
  backend **hoàn toàn biến mất** khỏi app (là ý đồ, không phải bug)

### 7.4. `skills/` — thư mục hướng dẫn cho agent

Một skill = **một thư mục** chứa `SKILL.md` (front-matter card + hướng dẫn).

**Bốn đường vào:** viết tay · upload folder (drag & drop, `skillFolderRefusal()` kiểm card có **cả**
`name` lẫn `description`) · catalog công khai (**114 `SKILL.md`, 16 plugin, ~6.1 MB** bundle trong
`assets/public_skill/Anthropic/`) · chat đề xuất (menu "Turn this into a skill…" → model trả block
```` ```skill ```` JSON → `SaveSkillBar`).

`copySkillFolder` **xoá `to` trước rồi copy** — skill là một đơn vị, merge sẽ để lại file mồ côi.

#### Ba bug đã tìm ra khi đọc

1. ⚠️ **"Share to all agents" có thể xoá sạch chính skill đó.** `_targets` luôn thêm `ShareTarget.all`,
   và `all.agents` **bao gồm agent của tab hiện tại**. Với row ở tab Hermes: `from == to`, mà
   `copySkillFolder` mở đầu bằng `delete(to)` → xoá luôn `from`. Cần guard `if (from.path == to.path) return;`
2. ⚠️ **"Reinstall Grid's skills" luôn cài cho Hermes**, bất kể đang ở tab nào — plane lấy từ
   `extensionAgentProvider` (cố định `hermes`). Đứng ở tab Codex bấm nút → ghi `~/.hermes/skills`,
   đọc lại `~/.codex/skills` vẫn rỗng, toast báo "up to date"
3. ⚠️ **`SaveSkillBar` đi thẳng `SkillAuthor`, bỏ qua `SkillsController`** → skill chỉ nằm ở
   `~/.grid/skills/user/<slug>` — **library, nơi không agent nào đọc**

Thêm: cài một public skill cho agent thứ hai bị từ chối (`exists()` true vì library đã có), và
`SkillSource.store` ('Library') **không có tab** trong UI.

### 7.5. `plugins/` — tool backend của agent

Khác skill: *"Plugins give it new powers; skills teach it what to do with them."*

Wrapper mỏng quanh CLI agent, đọc lại JSON sau mỗi lệnh (**không optimistic**):
`hermes plugins list/install/enable/disable/remove` · `claude plugin …`.

- **Codex `plugins == null` vĩnh viễn** — `[plugins.*]` trong `config.toml` do app ChatGPT desktop ghi,
  không có CLI verb nào drive được
- Màn hình **`devOnly`** — chưa ship cho user thật, đúng vì Codex có plane null

### 7.6. `scheduled/` — task chạy theo lịch

**Không tự schedule gì cả** — là client viết-qua-CLI lên scheduler của Hermes, đọc ngược
`~/.hermes/cron/jobs.json`, và tự làm phần Hermes không làm: mang kết quả vào tab Chat, badge chưa đọc,
desktop notification, ghim model.

#### Tạo task — chuỗi 10 bước

```
1. hermesModelRefusal(model)               chặn model Claude/Codex seat
2. ensureModelForSelectedGrid()            ghi ~/.hermes/config.yaml — THIẾU BƯỚC NÀY thì
                                           mọi run fail bằng "no model configured"
3. applyBeforeSaving()                     ghi platform_toolsets.cron TRƯỚC khi job tồn tại
4. before = {id hiện có}
5. hermes cron create <schedule> <prompt> --name <n> --deliver local [--workdir <d>]
6. đọc lại jobs.json
7. created = job mới ∉ before               ← cron create KHÔNG in ra id
8. _pin(created.id, model)                  ← qua Python nội bộ của Hermes (xem dưới)
9. projectTasksProvider.assign(jobId, projectId)
10. runNow → hermes cron run <id>
```

#### Ghim model — đường vòng qua interpreter của Hermes

`hermes cron create/edit` **không có `--model`** (v0.19.0), nên app resolve symlink binary `hermes`,
tìm `python` bên cạnh, rồi chạy `python -c "from cron.jobs import update_job; …"`.
Re-arm là **hai lần ghi**: pin model rồi unpin (chỉ unpin mới khiến Hermes re-snapshot); pin trước để
một tick chen giữa vẫn chạy đúng model. `TODO(BE)`: xin flag `--model`.

#### Sweep giao kết quả (30s/lần)

1. **`await chatSessions.restored`** — bắt buộc. Sweep chạy trong lúc đang đọc chat sẽ tạo *chat thứ hai*
   cùng id và kết quả hôm nay thay thế lịch sử
2. Quét `~/.hermes/cron/output/<jobId>/*.md`, parse thời gian từ **tên file** `YYYY-MM-DD_HH-MM-SS.md`
3. `deliverFromAgent(id: 'task-<jobId>', …)` → chat + inbox digest + unread badge + notification
4. **`fallbackToAuto(served)`** — chạy trong sweep (vòng lặp duy nhất chạy dù màn Scheduled có mở hay không).
   `served` rỗng = **"chưa load"**, không phải "grid không phục vụ gì" — nếu không, sweep đầu tiên sau khi
   mở app sẽ re-point sạch mọi task

#### Task power

`fullAccess` | `noCommands` → ghi `platform_toolsets.cron = ['file','web','browser','skills','vision','todo','memory','session_search']`
+ `approvals.cron_mode = 'deny'`.

> ⚠️ **`noCommands` không chặn ghi file.** Hermes chỉ hỏi về edit qua ACP, không bao giờ trong cron;
> toolset `file` gộp read+write, không có nửa read-only. Và đây là giới hạn **Hermes-wide, không per-task**.

### 7.7. `messaging/` — config writer cho Hermes gateway

**Không có API, không websocket, không cloud bot.** Ghi `~/.hermes/.env`, sửa `config.yaml`, rồi chạy
`hermes gateway install` + `restart`. Tin nhắn Telegram/Discord/Slack **không bao giờ đi qua app Flutter**.

| | telegram | discord | slack |
|---|---|---|---|
| credentials | `TELEGRAM_BOT_TOKEN` | `DISCORD_BOT_TOKEN` | `SLACK_BOT_TOKEN` **+** `SLACK_APP_TOKEN` |
| allowlist | `TELEGRAM_ALLOWED_USERS` | `DISCORD_ALLOWED_USERS` | `SLACK_ALLOWED_USERS` |
| home channel | `TELEGRAM_HOME_CHANNEL` (userId) | — | — |

**Ba invariant, mỗi cái từng là bug:**

1. Phải là **`restart` chứ không `start`** — gateway đang chạy sẽ bỏ qua `start` và không đọc lại `.env`
   → bot hiện "connected" nhưng **không trả lời ai cả**
2. **`_pointAtGrid()` phải chạy trước mọi thứ** — Hermes giữ config riêng; chưa nêu tên grid thì nó không
   có model nào để gọi
3. Allowlist rỗng bị từ chối — `.env` rỗng nghĩa là **bất kỳ ai** cũng nhắn được

> ⚠️ **Pin toolset đã bị GỠ theo quyết định sản phẩm.** `HermesPlatformPolicy` giờ chỉ còn chức năng
> **undo**. Tin nhắn Telegram giờ chạm đúng bộ tool như chat trong app, **và không ai được hỏi**.
> Allowlist của bot là gate duy nhất còn lại — nó là **ranh giới bảo mật**, không phải tiện ích.
> `docs/messages-tab.md` §5 mô tả hành vi cũ và **đã lỗi thời**.

Thêm: token nằm plaintext trong `.env`, và **`.bak` giữ lại token đã xoá** (`EnvFile._write` copy `.bak`
trước **mọi** lần ghi, kể cả lần ghi của `removeEnv`).

### 7.8. `network/` — grid P2P

**Sở hữu:** tạo/đổi tên/xoá grid qua control plane, membership, đọc trạng thái sống từ relay, suy ra
"grid này mạnh cỡ nào", và toàn bộ nội dung "How to use".

#### Ba trục quyền — hay bị lẫn

| | Nghĩa | Gate cái gì |
|---|---|---|
| `role == admin` (`isOwner`) | Chủ grid | Delete, Rename, AutoRouterCard |
| `isProvider` = `scopes.contains('provider:poll')` | **Capability**, không phải role | `ProviderView` mở form join |
| `canManageProvider` = `isOwner \|\| isProvider` | | Tab Members |

#### Poll overview

`GridPowerPill` (top bar) là **nơi duy nhất mount refresher**. Cadence **60s** bình thường, **15s** khi
hover panel; pause khi window ẩn. Hệ quả: **Settings pane không mount `AppTopBar` → pane chi tiết grid
trong tab Grids không tự refresh.**

- Mọi thứ derive đọc qua `gridOverviewSnapshot = gridOverviewProvider.select((a) => a.value)` — không bao
  giờ `.asData`. Đọc `.asData` làm số về 0 mỗi vòng poll
- **Value equality của `GridOverview` là load-bearing** — không có nó, mỗi poll đưa Riverpod object mới
  ⇒ cả đồ thị derive recompute, và trúng lúc một màn hình đang mount ⇒ `setState() during build`

#### "How to use" — cấu hình client app

`ClientAppDetector` dò: `$HOME/<configDir>` tồn tại → `/Applications/<name>.app` →
`HostEnvironment.findExecutable()`.

| App | File ghi | Cách |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | merge block `env` |
| Hermes | `~/.hermes/config.yaml` + `.env` | `YamlEditor` tại chỗ (giữ comment) |
| Codex | `~/.codex/config.toml` + `.env` | **re-encode toàn bộ TOML** (mất comment/thứ tự key) |
| Buzz, OpenClaw | (tắt) | writer + snippet vẫn compile + test |

Mọi write đều `_backupThenWrite`.

#### Cạm bẫy

- **`isPublic` cố ý ngược**: `permissioned-providers` = **Public**, `permissioned-public` = **Private**.
  Có comment "Do NOT fix this"
- **Rename dùng path khác create/delete**: `PATCH /v1/grid/networks/{id}` vs
  `/v1/grid/managed-networks/{id}`. `TODO(BE)`: endpoint rename **không validate gì**
- **`kAutoModelId`**: relay quảng cáo model ảo `auto` kể cả khi không node nào phục vụ
- **Hermes `toolsets:` là allowlist, không phải danh sách bổ sung** — key tồn tại là mọi toolset không có
  tên trong đó bị tắt. Đã từng làm agent chỉ browse được
- **Hermes `approvals.mode` bị ép `manual`** — mặc định `smart` cho LLM phụ tự duyệt `rm -rf`
- Cờ `advertises_*` là **tri-state**: `null` = "relay không nói", **không phải "không"**

### 7.9. `provider_node/` — máy này đóng góp gì

Sở hữu vòng đời engine (`grid join` / `grid leave`), catalog engine hosted, dò server
OpenAI-compatible đang chạy, và tab **Model Engines**.

```dart
sealed ProviderRunState = Idle | Active(grid, log, starting, model) | Stopping | Stopped | Failed(message)
```

**Một máy = một engine**: `canAddEngine(serving) => serving.isEmpty`.

#### Reconcile — nhận lại engine sống sót qua restart

Scan `~/.grid/run/engines/<gridId>/*.json` → `firstLiveRun()` chọn record có pid còn sống
(`kill -0`) → đọc log đuôi 400 dòng → `ProviderRunActive(starting: false)`.

#### Ba kiểu engine

| Kiểu | argv |
|---|---|
| local | `join <grid> --serve <gguf> --endpoint-port <free> [--advertise-as] [--ctx-size] --name <node>` |
| external | `join <grid> --at <url> -m <model> --ctx-size 200000 --name <node>` |
| API/seat | `join <grid> --api <kind> [-m …] --name <node>` + env `{KIND_API_KEY}` |

`kApiProviders`: `openai` (key), `claude` (seat `claude` binary), `codex-cli` (seat `codex` binary).

#### Retry logic

- log cuối chứa `'already joined'` → `_leaveEngine` rồi retry **một lần**
- log cuối chứa `'already in use'` → rebuild args với **port mới** rồi retry
- `findFreePort()` bind `127.0.0.1:0` rồi đóng — có khe hở race, retry một lần

> ⚠️ **`grid leave <grid>` cố ý KHÔNG có `--engine`**: ở remote mode CLI khoá run record bằng engine id
> cố định `remote`, còn `--name` chỉ là `meta_name` hiển thị; `leave --engine` match theo endpoint URL /
> model / label chứ **không** theo tên. Truyền `--engine <name>` từng khớp rỗng và để engine tiếp tục
> serve sau khi app đóng.

`TODO(BE)`: engine detached ghi log vào `~/.grid/run/engines/` chứ không qua process này, nên
`localProviderEndpointProvider` **không còn fire** → Playground rơi về đường relay.

### 7.10. `models/` — quản lý GGUF

Quét `~/.grid/models`, gom shard split-GGUF thành một model, `grid pull` / `grid rm` / `grid ctx`,
suy `--advertise-as`, cài `llama.cpp`.

**Model manager** = dialog 980×720, sidebar 340px (search debounce 350ms / sort / install-filter) ⟂
detail pane. Suggest theo phần cứng: `grid device-info --json` → `POST /v1/grid/catalog {"device": …}`
(app **không diễn giải field nào**).

#### Hồi quy do split view thay UI cũ — 4 thứ

1. **Không còn cách huỷ download** — `ModelPullController.cancel()` chỉ được gọi từ `DownloadRow` đã chết
2. **`ModelPullFailed.message` không bao giờ hiển thị** — detail panel bắt state rồi chỉ tắt spinner
3. **Xoá split-GGUF chỉ xoá 1 shard** — các shard `-00002-of-00005…` ở lại đĩa vĩnh viễn
4. **Không có guard "đang serve" khi xoá** — `isModelInUse` chỉ nằm ở file đã chết

**Dead code đo được:** `suggested_models_section.dart` (471 dòng), `download_row.dart`,
`manager_search_field.dart` (0 import mỗi cái), `buildModelShelf`, `catalogModelsProvider`.

**`grid pull` không surface exit code** — `GridCliServiceImpl.pull` đóng stream khi process exit,
bất kể mã thoát. Hệ quả: một `grid pull` fail (exit 1) tạo stream kết thúc **bình thường** →
tab Debug hiện download thất bại là **màu xanh**. Chỉ `ModelPullController` sống sót nhờ **rescan đĩa**
hậu kiểm.

### 7.11. `playground/` — transport + render (thư viện lõi của Chat)

> **Playground là thư viện lõi của Chat tab, không phải ngược lại.**

Ba transport + toàn bộ render layer:

| Đường | Endpoint | Streaming |
|---|---|---|
| chat | `POST {relay}/chat/completions` | ✅ token-by-token (`ChatSendStreaming` **cumulative**) |
| responses (Codex seat) | `POST {relay}/responses` body `{model, instructions?, input, stream: true, store: false}` | ❌ **drain hết rồi mới yield một `ChatSendSuccess`** |
| media | `POST {relay}/media/image/generate` \| `/edit` \| `/video/i2v` | `ChatSendGenerating` (idle timeout 5 phút) |
| local smoke test | `POST {localBaseUrl}/v1/chat/completions` | ✅ |

**Fallback quan trọng:** nếu **không dòng `data:` nào** xuất hiện, parse cả body qua `chatStreamWholeBody`
→ dành cho relay bỏ qua `stream: true`.

#### Render một reply

```
parseMessageSegments(text)     ← _mediaPattern bắt fence TRƯỚC mọi thứ, kể cả fence chưa đóng
  → một SelectionArea cho CẢ message  (không MarkdownBody(selectable: true) —
     cái đó dựng một EditableText cho MỖI rich-text node)
  → _splitByTable theo delimiter row |---|:--:|  (không theo dấu |)
     run có table → full column · run không → maxWidth 760
  → MarkdownBody(gitHubFlavored, softLineBreak: true, builders: {'pre': CodeBlockBuilder})
     language == 'chart' && !openFence → ChartSpec.parse → MessageChart (CustomPaint thuần)
     fence chưa đóng → GIẤU nút Copy + TẮT syntax highlight
  → media: LocalMediaView / InlineImage(CachedNetworkImage) / InlineVideo(media_kit) / InlineAudio
```

**Invariant:** `ChatSendStreaming.text` là **toàn bộ** reply tới lúc này; `ChatDelta.text` là **mảnh**.
Nhầm hai cái này → text nhân đôi.

**Rủi ro:** ảnh đọc fail bị **bỏ im lặng** (UI vẫn hiện trong bubble user); ảnh đọc bằng
`readAsBytesSync` + `base64Encode` **trên UI isolate**; **không cap history** — gửi toàn bộ transcript
mỗi lượt, kể cả `promptBlock` 20.000 ký tự của từng file.

### 7.12. `projects/` — thư mục agent được phép đọc

**Hoàn toàn app-owned — không CLI, không HTTP.**

`Project{id, name, path, instructions, memory, pinned}` → `~/.grid/app/projects.json`.

**`projectStandingBrief(project)`** = `instructions` + `"Remember about this project:\n- <fact>"` —
**hợp đồng duy nhất** để memory thực sự tới agent, và **chỉ đi kèm lượt mở đầu của session**.

**Probe folder còn/mất:** `Future.wait` song song, timeout 5s, **timeout/exception ⇒ coi như CÓ**
(nói "thư mục của bạn biến mất" chỉ vì stat chậm là lời nói dối tệ hơn). Trước đây
`Directory.existsSync()` nằm trong **4 `build()`** và block UI thread hàng giây trên network share —
cho một cái badge.

Rail 4 card (Instructions / Context / Scheduled / Memory), **key theo project id** để đổi selection không
mang ghi chú gõ dở sang project khác.

⚠️ Bẫy đặt tên: `agent_workspace.dart` nằm trong `features/projects/logic/` nhưng nói về workspace của
**chính agent** (`~/.grid/app/agent-workspace`), *không* phải project của user.

### 7.13. `auth/` — device login

`grid --remote login --no-browser` → parser bắt dòng đầu bắt đầu bằng `http` làm URL và dòng `Code:`
làm user code — **theo hình dạng, không theo nhãn**, nên đổi chữ trong prompt CLI không làm hỏng login.

`selectedNetworkProvider` resolve theo thứ tự: `_selectedId` (session) → `chatPrefs.networkId` →
`activeRemoteGridProvider` → `creds.active`. `select()` ghi `chatPrefs`, **không bao giờ** ghi `~/.grid`.

**Session hết hạn:** `CliResult.sessionExpired` là **string-match trên 4 câu tiếng Anh** — CLI đổi wording
là app im lặng ngừng phát hiện. `onExpired()` → thử `grid sync` (dùng lại session token, không cần
browser) → thất bại thì `needsLogin` → `LoginScreen`.

Logout gọi `shutdownServing()` **trước** — không để engine còn phục vụ khi tài khoản đã ra.

### 7.14. `onboarding/` — preflight → installer → choice

**Preflight** (mọi lần mở app): `grid --remote --version`.
Exit **âm** → `_signalError` (`-9` = Gatekeeper/AMFI chặn helper chưa ký / còn quarantine).
Exit dương → `diagnoseCliFailure` giữ **dòng cuối cùng khác rỗng**, không phải cả traceback.
`stdout` rỗng **không phải lỗi** (checkout từ source exit 0 mà không in version).

**Installer** — 2 pha, dừng ở pha đầu fail: `_ensureGrid()` (`grid sync` nếu chưa có grid) →
`_installAssistant()` (`uv tool install 'hermes-agent[acp,mcp]'`). Trạng thái từng hàng **suy ra từ máy
thật**, không từ cờ do installer đặt.

⚠️ `_installAssistant` truyền `includeEngine: false, includeModel: false` nhưng **để mặc định
`includeMedia`**. Bật lại `kMediaSetupEnabled` là first-run installer âm thầm nhận thêm
`engine install comfyui` + `engine pull image_generation` (vài GB) — đúng thứ màn hình này cam kết không làm.

**Choice screen:** seat CLI đã đăng nhập sẵn · "Run a model on this computer" (chỉ macOS) ·
API key disclosure · "I'll set this up later".

### 7.15. `auto_router/` — model ảo `auto`

Domain duy nhất nói chuyện control plane **qua CLI** (`grid router …`) và là **chỗ duy nhất trong app
parse stdout** thay vì đọc `~/.grid` — vì config router nằm trên control plane.

**Advisor chain** = chuỗi cloud AI được hỏi để xếp hạng model của grid cho từng request.
`kMaxAdvisors = 3`, order-preserving, có promote.

**Thứ tự bắt buộc:** `set-advisors` **trước** `enable` — control plane từ chối `enable` khi chưa có advisor.

`autoEnableForOwner()` no-op khi `config.enabled || config.hasAdvisors` — routing đang bật **hoặc** owner
đã cố ý tắt (advisor sống sót qua `disable`). Cả hai đều là state của user.

### 7.16. `command_palette/` — ⌘K

Sealed `CommandItem`: `OpenChat` · `NewChat(project?)` · `OpenTask` · `AddProject` · `OpenSettings` · `GoTo(section)`.
Xếp hạng 3 bậc: label bắt đầu bằng query > có từ bắt đầu bằng query > chứa query.

- **`chats:` phải là `liveConversations(...)`** — archive một chat là để nó biến khỏi search luôn
- `kMaxMatchesPerGroup = 8` giữ chi phí phẳng khi lịch sử dài (`ListView(shrinkWrap: true)` layout **mọi** hàng mỗi keystroke)
- **Pop trước, act sau**, dùng `navigator.context` — `AddProjectCommand` mở dialog phải bám navigator sống lâu hơn palette
- ⚠️ `AppTheme.watch` **hoàn toàn vắng mặt** trong cả hai file → bug flip theme

### 7.17. `prompts/` — thư viện `/`

Cố tình đơn giản — chỉ boilerplate có tên, khác hẳn skill. `slashQuery` yêu cầu bắt đầu `/` và phần còn lại
**không chứa whitespace** (`/a b` → null, user đang viết câu thật).
`_insertPrompt` **ghi đè** cả ô nhập (khác `_insertMention` chèn tại caret).
Tên được slug **ngay lúc đọc file** — thư viện lưu trước khi có luật slug tự sửa mà không cần user mở lại.

### 7.18. `appearance/` — theme, font, detail mode

Không có `logic/` — tất cả đọc/ghi `chatPrefsProvider`.

- `ThemePreviewTile` vẽ `_MiniApp` bằng **token thật** ở brightness đó qua `AppTheme.as` —
  không hardcode xám, nên preview hỏng đúng lúc palette đổi
- `_SizeField._commit()` chạy khi Enter hoặc **mất focus**, không phải mỗi phím — gõ "9" trên đường tới
  "19" sẽ resize cả app và làm dịch chuyển chính cái field đang gõ
- `_TypePreview` dựng **widget thật** `MarkdownCodeBlock` — chính thứ transcript chat dựng
- **Mặc định theme là `light`, không phải `system`**
- ⚠️ **Chỉ macOS mới có danh sách font** — channel `grid/fonts` chỉ cài trong `AppDelegate.swift`.
  Trên Windows/Linux picker chỉ còn "System"

### 7.19. `node_setup/` — wizard cài máy

`buildSetupPlan` là **hàm thuần**:

| Điều kiện | argv | isDownload |
|---|---|---|
| `!engine.llamaInstalled` | `engine install llama.cpp` | |
| `!hasModels` | `pull <spec>` | ✅ |
| `!installedAgents.contains(hermes)` | `[]` (app tự cài) | |
| `!hasMediaEngine` (tắt) | `engine install comfyui` | |
| bundle thiếu file (tắt) | `engine pull image_generation` | ✅ |

**"Missing" được đo theo engine của Grid, không theo máy**: máy đã có Ollama vẫn được lập plan cài
`llama.cpp` — trước đây plan rỗng khiến grid không có model nào.

**Auto-host** chỉ chạy **sau khi model nền tải xong**, không bao giờ lúc launch
(*"a launch hook here is a regression, not a convenience"*), và **không bao giờ tự đưa máy lên grid public**.

`kMediaSetupEnabled = false` — toàn bộ nhánh ComfyUI tắt bằng một hằng, code vẫn compile + test.

### 7.20. `debug/` — nhật ký lệnh (dev-only)

Ring buffer **200 mục, chỉ RAM, chỉ phiên hiện tại**. Thứ sống sót qua crash là file trong `~/.grid/logs`
— đó là toàn bộ lý do tồn tại của nút "Open logs".

**Copy để chạy lại** (`logAsCommand`):
- HTTP → `curl -sS -X POST '<url>' -H "Authorization: Bearer $GRID_API_KEY" -d '<body>'` — **tên biến,
  không bao giờ giá trị**
- CLI → `KEY="$KEY" grid --remote join …`, prompt qua heredoc `<<'GRID_PROMPT'` (tag mở **có nháy** để
  shell không expand `$`/backtick)
- Dòng `#` mang outcome + cảnh báo "body đã bị cắt" / "cần biến env này"

`_WhichGridCard` hiện `gridPathProvider` + `GRID_BIN` + preflight; Recheck invalidate cả hai →
**dựng lại toàn bộ decorator stack**.

### 7.21. `app_update/` — Sparkle

Feed CI bake `https://github.com/<repo>/releases/latest/download/appcast-{arch}.xml`.
Token `{arch}` tồn tại vì app là **một universal binary** nhưng hai DMG khác nhau ở arch của **sidecar
`grid` bên trong** — feed sai sẽ đưa DMG arm64 cho máy Intel.

**Cờ `_answered` là fix cho một bug copy thật:** Sparkle báo "không có update" **hai lần** — một qua
`onUpdaterUpdateNotAvailable`, một nữa xuống **kênh error** với message `You're up to date!`.
Không guard → toast đỏ "Couldn't check for updates: You're up to date!". Fix dựa trên **thứ tự**,
không dựa message (match chuỗi chỉ đúng ở tiếng Anh).

Build local luôn `UpdateUnsupported` (`GRID_APPCAST_URL` chỉ bake trong `release.yml`).

### 7.22. `review/` — diff của project, cạnh hội thoại (44 file, domain mới lớn nhất)

**Sở hữu:** đọc một repo Git thành thứ xem được, stage/unstage, commit, push, comment từng dòng, và nhờ
model viết commit message. **Không sở hữu:** chat, project, agent — nó được *đưa cho* một thư mục và
*trả về* một câu tin nhắn (`onAskAgent`). Dây nối nằm ở `chat/presentation/panel_feature_view.dart`.

Sống trong tab của panel chứ không phải một màn hình riêng: review là việc làm **trong lúc** agent chạy —
đi sang màn khác để xem nó vừa viết gì nghĩa là rời khỏi chính cuộc chat đã yêu cầu điều đó.

#### `ReviewScope` — sealed 6 nhánh, mỗi nhánh là **một cặp lệnh Git khác nhau**

Không phải filter trên một câu trả lời chung:

| Scope | `_range()` | Nguồn danh sách file |
|---|---|---|
| `LastTurnChanges` | `HEAD` | `status`, lọc theo path agent vừa sửa |
| `UncommittedChanges` (mặc định) | `HEAD` | `status` |
| `UnstagedChanges` | *(rỗng)* | `status` |
| `StagedChanges` | `--cached` | `status` |
| `CommittedChange(sha)` | `null` → dùng `git show` | `show --name-status` |
| `BranchAgainst(ref)` | `<ref>...HEAD` | `diff --name-status` |

Hai getter chặn control vô nghĩa: `canStage` (commit/branch đã chốt rồi, tick ở đó là nút không làm gì)
và `showsUntracked` (file Git chưa từng biết không nằm trong commit, index hay branch nào).

`BranchAgainst` dùng **ba chấm** (`merge-base`) chứ không hai — nếu không, commit landing lên `main`
*sau khi* nhánh này tách ra sẽ đọc thành "nhánh này xoá chúng đi".

#### `review_argv.dart` — mọi argv Git nằm ở đây, dạng hàm thuần có test

*"Một flag sai fail y hệt một repo rỗng"* (§7 conventions). Sáu thứ đã học bằng bug:

- **`git show` phải có `--format=`** — không thì nó in header commit của chính nó lên trên diff, và
  "file" đầu tiên parse ra là dòng subject
- **`status --porcelain=v2 -z`, không phải v1.** v1 quote/escape path non-ASCII → **tên file tiếng Việt
  về là rác**, và dạng rename của nó nhập nhằng. Giá phải trả: path gốc của rename là **một field
  NUL-terminated riêng sau record**, nên không thể split-rồi-map thẳng
- **Rename phải truyền CẢ HAI path.** Chỉ đưa path mới thì Git không có gì để ghép cặp và báo một file
  hiện ra từ hư không — **mọi dòng "added"**, tức ngược hẳn nghĩa của rename
- **File untracked dùng `diff --no-index -- <nullDevice> <path>`.** `git diff` thường **không in gì cả**
  cho nó. Và `--no-index` báo "hai bên khác nhau" bằng **exit code 1** — coi đó là lỗi thì diff của mọi
  file mới **trắng vĩnh viễn**
- **`unstage` dùng `reset`/`rm --cached`, KHÔNG dùng `git restore --staged`** — `restore` có từ Git 2.23,
  app đỡ tới 2.20. Repo chưa có commit nào thì không có `HEAD` để reset → drop khỏi index
- **"Stage all" liệt kê **path đang hiện**, không phải `git add -A`.** Dưới scope hẹp (last turn),
  "everything" nghĩa là những file trên màn hình — `-A` sẽ **lặng lẽ nhét việc user chưa từng thấy vào
  commit của họ**. Batch 50 path/lệnh vì command line Windows giới hạn 32KB
- **`kLogFieldSeparator` là ``/``**, không phải `|` hay newline: mọi ký tự in được đều đã
  từng xuất hiện trong commit message của ai đó

#### Phân tầng

```
ReviewController (AsyncNotifier.family theo folder)
  └─ ReviewLoader   ← đọc: biết THỨ TỰ hỏi và làm gì với câu trả lời
  └─ ReviewActions  ← ghi: stage/unstage/commit/push + patch một file
       └─ GitRunner (infrastructure) ← chỉ biết cách spawn git
```

`ReviewLoader` để ngoài controller để test được bằng fake runner không cần Riverpod, và để ngoài
`infrastructure/` vì shape nó trả về là **của feature review**, không phải của tầng CLI.

- `branch` / `HEAD tồn tại?` / `upstream` / danh sách file được hỏi **song song** (`(a, b, c).wait`) —
  màn hình không phải chờ ba round-trip nối đuôi
- **File untracked được đếm dòng từ ĐĨA**, vì `--numstat` không nói gì về chúng. File mới hiện "0 dòng"
  là nói giảm đúng cái thay đổi user sắp commit. Cap 4MB → báo binary (thành thật về việc không biết,
  hơn là sai)
- `refresh()` **giữ nguyên list đang hiện**, không rơi về spinner — refresh làm trắng file đang đọc thì
  mất chỗ mỗi lần agent chạm vào một file
- ⚠️ **`build()` chỉ `watch` `reviewLastTurnPathsProvider` KHI scope là `LastTurnChanges`.** Watch vô
  điều kiện nghĩa là **6 lệnh `git` mỗi lần agent ghi một file** — một cơn bão spawn process sau một
  danh sách không ai đang nhìn

#### `ReviewState` — 4 nhánh vì **3 trong số đó user làm được gì đó**

`ReviewNeedsGit` (→ màn Git) · `ReviewNotARepo(folder)` (→ mời `git init`) · `ReviewFailed(message)` ·
`ReviewReady(snapshot)`.

`friendlyGitFailure()` dịch 8 họ lỗi Git sang câu hành động được — **và raw text luôn vào `appLog` bên
cạnh** (§6: humanise không bao giờ là bản ghi duy nhất). Đáng chú ý: lỗi credential nói *"push từ
Terminal một lần, sau đó máy nhớ và nút này chạy được"* — vì **chính app này** là thứ đã tắt prompt.

#### Commit

`CommitState` sealed 4 nhánh; `CommitFailed` mang cờ **`committed`** — push fail sau khi commit thành
công mà đọc thành "không có gì xảy ra" thì user **commit cùng một việc hai lần**.

- `commitArgv` **cố ý không có `-a`** — stage là quyết định của user, làm từng file trên màn này
- `includeUnticked` stage nốt phần còn lại **bên trong `run()`**, để stage + commit + push là **một lần
  chạy với một lỗi để báo**
- Nhánh riêng `pushOnly()` — việc đã commit ở terminal, hoặc một lần push fail trước đó, đang chờ nó;
  và **không còn gì để mô tả**
- `setUpstream: snapshot.upstream == null` — nhánh chưa từng push thì Git từ chối `push` trần

**`CommitMessageWriter`** — một call `chat/completions` blocking qua `ChatTransport` chung, cùng target
`resolveOneShotTarget` với skill generator (engine local nếu đang serve, không thì relay). Cap
**12.000 ký tự** patch, và **phần bị cắt được NÓI RA** (`[… the rest of this change is not shown]`).

> ⚠️ **`_patch()` đọc HAI lần, không một.** `git diff` ở mọi dạng đều **không nói gì** về file Git chưa
> biết, nên một thay đổi *toàn bộ là file mới* về rỗng và nút trả lời "không có gì để mô tả" trên một
> danh sách đang hiện +32.

`tidyCommitMessage()` thuần và **cố ý dễ dãi** — model trả về fence bọc cả câu trả lời, tiền tố
`Commit message:`, subject trong ngoặc kép, dấu chấm cuối dòng đầu (dòng đầu commit không mang dấu chấm).

#### Đọc diff

`DiffViewPrefs{layout, wrap, ignoreWhitespace, collapsed}` — **một setting cho cả app**, không per-folder:
đây là sở thích *đọc diff*, không phải sự thật *về một repo*.

- **`kSplitDiffFrom = 620`** — dưới ngưỡng đó mỗi cột chưa tới 280px. Toggle **không được offer**, và lựa
  chọn đã làm trên cửa sổ rộng **lặng lẽ vẽ unified** cho tới khi có chỗ, thay vì băm mỗi dòng thành ba
- **`wrap` mặc định bật** — panel rộng 420–760px, và một dòng phải kéo ngang mới đọc hết là dòng không
  đọc hết
- **`ignoreWhitespace` là `-w` của Git**, không phải filter hậu kỳ: nó bỏ **cả dòng** chỉ khác nhau ở
  khoảng trắng
- **`reviewOpenHunksProvider` là tập NGOẠI LỆ, không phải sự thật.** "Collapse all" là một cờ; một hunk
  mở tay sau đó phải sống sót mà không tắt cờ cho mọi hunk khác. `hunkIsOpen()` là hàm thuần

**`CodeHighlight` có memo, và đó là điều kiện để diff scroll được.** Đo: một dòng Dart tốn ~170µs
tokenise; diff vẽ từng dòng một → một màn hình ≈ **8ms trong ngân sách 16ms của một frame**, tiêu lại
ở mỗi lần rebuild và mỗi lần scroll. Key theo *text + ngôn ngữ + brightness + base style*; cap 4.000 entry;
**grammar ném exception cũng được nhớ**, để một dòng không tô được không bị parse lại mỗi frame.

#### Comment từng dòng

`ReviewComment{path, side, line, text, code}` — **giữ trong phiên, không ghi đâu cả**, và UI nói rõ
"Local comment" để không ai ngồi đợi đồng nghiệp trả lời.

`DiffSide` bắt buộc phải có: dòng bị xoá chỉ tồn tại ở file cũ, dòng thêm chỉ ở file mới — "dòng 32" một
mình gọi tên **hai dòng khác nhau**. Với dòng context thì **file mới thắng**.

`commentsPrompt()` thuần, và **chính nó là toàn bộ tính năng** — nó dặn agent **đọc lại file quanh dòng
được trích trước khi sửa**, vì tới lúc agent đọc thì chính bản sửa trước của nó đã đẩy mọi thứ dưới
dòng 32 đi chỗ khác.

### 7.23. `terminal/` — shell thật trong tab panel

7 file, ~766 dòng. `flutter_pty` + `xterm`. Chi tiết pty ở §4.6.

**`TerminalSession` cố ý KHÔNG phải Riverpod notifier** — nhiều cái mở cùng lúc và panel chỉ hiện một,
nên chúng là *giá trị* mà controller giữ một danh sách. Thứ chúng không làm được là tự publish:
`onChanged` là cách controller nghe tin shell đã start hay chết.

Nó **giữ luôn `Terminal`** (emulator) chứ không dựng lại mỗi frame — **màn hình CHÍNH LÀ state**:
scrollback (10.000 dòng, bằng VS Code), con trỏ, lệnh đang gõ dở. Widget mà sở hữu nó thì mất sạch
mỗi lần đổi tab.

**Terminal thuộc về TAB, không thuộc về thư mục.** Hai tab Terminal là hai shell kể cả cùng project.
Và **thư mục bị khoá lúc tab mở ra** — shell đang chạy không dời được, `cd` là việc của user.

⚠️ **`endSession` được gọi từ `PanelTabs.close()`, không phải từ một watcher.** Watcher chỉ chạy khi có
người đang nhìn — còn việc này phải xảy ra **kể cả khi user đóng tab trên đường rời khỏi Chat**. Một pty
mồ côi là một process user không còn nhìn thấy, nói gì tới dừng.

⚠️ **`_TerminalTab` phải có `ValueKey(tab.id)`** — cùng loại widget ở cùng slot, Flutter sẽ đưa id của
tab thứ hai cho element của tab thứ nhất, và tab mới hiện màn hình của tab cũ (hoặc không gì cả).

`ShellState` sealed 4 nhánh; **`ShellExited` không phải error state** — rời một terminal là cách một
terminal kết thúc. `restart()` **giữ nguyên scrollback** ở trên: transcript của thứ vừa hỏng thường
chính là lý do user mở lại.

### 7.24. `files/` — duyệt và đọc file của project

13 file, ~2.866 dòng. Cây thư mục + breadcrumb + viewer, trong một tab panel.

- **`filesBrowserProvider` là family theo TAB id**, không theo panel: hai tab Files là hai chỗ trong
  cùng project; dùng chung một selection thì tab thứ hai vô nghĩa — click ở đâu cũng dời cả hai
- **`filePreviewProvider` là `autoDispose`, và lý do thứ hai mới là lý do chính**: **agent ghi đè chính
  những file này trong lúc chúng đang hiện trên màn hình**. Một bản đọc được cache sẽ lặng lẽ hiện bản
  hôm qua của file vừa đổi một giây trước
- Cap: **1MB** / **2.000 dòng**. Viewer lay out một lượt (không virtualise) — đó là thứ cho phép cả file
  scroll và select như một khối. File bị cắt thì **nói ra**
- `decodeFilePreview` thuần: sniff 8KB đầu tìm byte NUL để quyết định binary; decode `allowMalformed`;
  **newline cuối kết thúc dòng cuối chứ không mở một dòng rỗng** — nếu không thì mọi file đúng chuẩn đều
  hiện một dòng ma ở đáy
- `reveal(path, root)` mở sẵn mọi thư mục cha, đi **xuôi từ root xuống** chứ không ngược từ file lên:
  separator của root là thứ platform đã ghi, ráp lại từ segment sẽ làm mất nó
- **Markdown có hai dạng, và "rendered" là dạng nghỉ.** `showSource` cưỡi trên **tab**, không trên file —
  người muốn đọc raw sẽ tiếp tục nhận raw khi click xuống cả thư mục tài liệu
- `file_kind.dart` (294 dòng) thuần string: **`FileGlyph` (vẽ gì) tách khỏi `FileAccent` (màu gì)** — một
  tá ngôn ngữ chung một glyph, một tá khác chung một hue. Tách ra là thứ ngăn nó thành enum-một-giá-trị-
  mỗi-đuôi-file
- Cây thư mục ẩn được (`showTree`), cùng lý do với file list của Review: panel dock ở 420px vốn đã ít
  bề ngang

### 7.25. `git/` — cài & chọn Git (3 file + seam ở `infrastructure/cli`)

Màn Settings ▸ Coding ▸ Git. Cơ chế ở §4.6; ở đây chỉ nói phần UI/controller.

`GitInstallState` sealed 4 nhánh. `GitInstallDone` mang **`GitStatus`**, không mang một câu đã hoàn
chỉnh — cùng một kết cục phải nói khác nhau: một lần re-check **không tìm thấy gì** vẫn kết thúc hoàn
hảo và **không được báo là thành công**.

> Nó tồn tại vì probe trả lời trong ~10ms — **dưới một frame**. Trên máy mà Git không đổi, bấm nút
> không làm gì nhúc nhích trên màn hình, và **không có outcome thì nó đọc ra như một control chết**.

`gitReadyProvider`: **chưa resolve = *chưa biết*, không phải *không có*** — để không có gì bảo user đi
cài Git trong lúc probe còn đang chạy.

### 7.26. `overlord/` — ⚠️ FAKE + UNREACHABLE

> **Hai vấn đề, cả hai phải nêu rõ:**
> 1. **Toàn bộ dữ liệu là GIẢ.** `overlordRepositoryProvider` bind cứng `FakeOverlordRepository`,
>    chạy trên `seedFleet()` hardcode — 4 GPU với **IP nội bộ, username (`samcardillo`), pid thật
>    (750284, 1190474) của máy người khác**. Nếu ship ra prod thì đây là leak.
> 2. **Màn hình KHÔNG THỂ MỞ ĐƯỢC.** Không có `ShellSection.overlord`, `section_view.dart` không map
>    tới nó, grep toàn repo (kể cả `test/`) ra 0 kết quả. **1.417 dòng dead code.**

Seam thiết kế đúng (`abstract interface class OverlordRepository { Stream<OverlordSnapshot> watch(); }`)
— nhưng chưa ai cắm gì vào. `StoragePanel` và `OrchestratorPanel` là stub "coming next", với 2
`GhostButton` **cố ý inert**. Toàn feature **không có một `AppTheme.watch` nào**.

---

## 8. Luồng xuyên suốt: một lượt chat end-to-end

```
[1] User gõ vào composer
    chat_composer.dart → ComposerKeys._onKeyEvent
      Enter (không Shift) && canSend → onSend()
      NUỐT Enter dù thế nào — turn không gửi được cũng không rớt line break thừa

[2] chat_view.dart:330  _send(modality)
      messageWithSnippets(message, _snippets)      ← đoạn bôi đen GỘP VÀO text
      captureTerminalContexts(attached, sessions)  ← CHỤP TERMINAL Ở ĐÂY, không sớm hơn
                                                     (terminal rỗng → bỏ hẳn, không gửi block rỗng)
      → chatSessionsProvider.notifier.send(network, model, message, modality, attachments, files, contexts)
      dismissedTerminals.clear()                   ← ✕ thuộc về bản nháp, hết nháp thì hết hiệu lực

[3] chat_sessions_controller.dart:696  send()
      bận? → _enqueue(QueuedTurn) và RETURN
      approvalFor(target, chatPrefs.approval)           ← đọc MỘT LẦN
      buildUserTurn(...)  → ảnh ghi ~/.grid/outputs
      _commit(phase: SendBusy)                          ← GHI ĐĨA TRƯỚC KHI GỬI
      viaAgent = agentAnswersTurn(modality, hasAttachments, agentInstalled)

[4] Serialize: runningAgentId != null && != id → vào _agentQueue
                                                 (_QueuedBubble "Finishing another chat first…")

[5] _dispatch()  → agentChangesProvider.attributeTo(id)   ← claim mọi file change
                  Stopwatch bắt đầu Ở ĐÂY (không ở send — chờ trong queue không tính giờ)
                  _senderFor(modality, attachments)

┌─────────────────────────────── NHÁNH A: RELAY (không agent) ────────────────────────────────┐
│ [6a] DefaultChatSender.send()                                                                │
│      isResponsesOnlyModel(model) ? POST {relay}/responses : POST {relay}/chat/completions     │
│      _messagesFor(history): system prompt + mỗi turn qua messageForModel                      │
│                             + promptBlock của từng file + ảnh base64 data URI                 │
│      commandLogProvider.begin(http, …) → tab Debug + app_https.log                            │
│ [7a] HttpChatTransport.stream — SSE, `data:` → chatStreamDelta → ChatDelta(mảnh)              │
│      tích luỹ vào StringBuffer → yield ChatSendStreaming(TOÀN VĂN tới giờ)                    │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────── NHÁNH B: HERMES (ACP, session dài) ─────────────────────────────┐
│ [6b] HermesChatSender.send()                                                                 │
│      resetAgentFeed(_ref)  ← ĐỒNG BỘ, TRƯỚC MỌI await                                        │
│      hermesGridLink.point(network, model)                                                    │
│        → ClientAppConfigurator.apply → ~/.hermes/config.yaml (+ .bak)                         │
│        → ensureRuntimeSupport() fire-and-forget · cron.followModel(model) re-arm             │
│      _sessionFor(key: networkId|model|conversationId|workdir)                                │
│        continue? → chỉ gửi history.sublist(seen)                                             │
│        fresh?    → close() cũ, _makeRoom() (LRU 5 PROCESS), Process.start(hermes acp)         │
│ [7b] Handshake: id 0 `initialize` → id 1 `session/new {cwd, mcpServers: []}`                  │
│      mcpServers RỖNG — MCP của Hermes đến từ config.yaml                                     │
│      sessionId rỗng ⇒ complete lỗi ngay (retryable: false)                                   │
│ [8b] session.approvalMode = … (theo mode lúc bấm Send) → `session/prompt`                     │
│ [9b] session/update:  tool_call → activityLog.upsert                                          │
│                       agent_message_chunk → HermesAcpMessage (DELTA — sender write() cộng dồn)│
│                       plan → planLog.replace (thay toàn bộ)                                   │
│      permission request → decideHermesPermission → AgentPermissionCard pin trên composer      │
│      edit → agentChangesProvider.record(before, after) → AgentChangesBar (undo thật)          │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────── NHÁNH C: CODEX (exec, 1 process/lượt) ─────────────────────────────┐
│ [6c] codex exec [resume] --json --skip-git-repo-check                                        │
│        -c sandbox_mode="danger-full-access"  ← KHÔNG hỏi ai                                  │
│        -c model / model_provider / model_providers.grid-app.{name,base_url,env_key,           │
│           wire_api="responses", supports_websockets=false}                                    │
│        (resume ? <threadId> : -C <workdir>)                                                   │
│      env {GRID_APP_API_KEY}  ← KHÔNG dùng GRID_API_KEY: Codex load ~/.codex/.env và           │
│                                dotenv đó THẮNG env process cha                                │
│      prompt qua STDIN (tránh tràn argv khi replay history)                                    │
│ [7c] parseCodexEvent: agent_message (TOÀN VĂN) · command_execution/web_search/mcp_tool_call   │
│                       · todo_list → plan · file_change (chỉ khi status == completed)          │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────── NHÁNH D: CLAUDE CODE (-p, 1 process/lượt) ──────────────────────────┐
│ [6d] planClaudeBrowser() → lane extension / cdp / none (mọi outcome log kèm LÝ DO)            │
│      ClaudeTurnMcpConfig().write(extra) → ~/.grid/app/claude-mcp-config.json                  │
│        đọc ~/.claude.json, giữ CHỈ entry marker `_grid`, + browser extra                      │
│        write hỏng → null → BỎ CẢ HAI FLAG (path không tồn tại làm chết turn)                  │
│ [7d] claude -p --output-format stream-json --include-partial-messages --verbose               │
│        --permission-mode bypassPermissions --model <m>                                        │
│        [--chrome] [--mcp-config <p> --strict-mcp-config] [--resume <sid>]                     │
│      env: claudeCodeEnv(...) — ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL/…                  │
│           lane extension → env RỖNG + dropEnvironment: kClaudeRelayEnvKeys                    │
│      prompt qua STDIN                                                                         │
│ [8d] ClaudeStreamParser (có state):                                                           │
│        stream_event.content_block_delta.text_delta → _partial → ClaudeMessageEvent(TOÀN VĂN)  │
│        assistant.text → clear _partial, push _completed   ← chặn đếm đôi                      │
│        tool_use TodoWrite → plan · Write/Edit → ClaudeFileWriteStarted                        │
│        result → THẮNG TUYỆT ĐỐI mọi text ráp từ block                                         │
│      ClaudeFileWriteStarted → _readNow(path) ĐỒNG BỘ (await sẽ đọc chính kết quả của write)   │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

[10] Agent gọi tool của connector?
       → POST http://127.0.0.1:<port>/c/<connector>/mcp  (ConnectorBridge)
       → đọc token TƯƠI từ tokens.json (không cache) → _fresh() renew nếu cần
       → transport mcp?  McpProxy.forward → provider (gắn headers credential, unwrap SSE `data:` cuối)
         transport rest? RestInvoker → dựng HTTP từ template, kiểm `required` tại đây

[11] chat_sessions_controller.dart:878  updates.listen — fold sealed ChatSendUpdate
       ChatSendGenerating  → withPhase(SendGenerating)
       ChatSendStreaming   → firstToken = clock.elapsed (lần đầu có text non-blank)
                             withPhase(SendStreaming(text))  ← text là TOÀN BỘ, UI THAY chứ không nối
       ChatSendAgentSession→ nhớ sessionId
       ChatSendSuccess     → append reply, _commit(SendIdle), _adoptAgentName, _announceTurn
       ChatSendFailure     → GIỮ phần đã stream (partial ?? SendStreaming.text)
       Mọi update kiểm _find(id) == null → chat bị xoá giữa chừng thì bỏ, không hồi sinh

[12] _finish(id) → _releaseAgentSlot → ƯU TIÊN _drainQueue(id); queue rỗng mới _advanceGoal

[13] Render: _Transcript cache widget theo IDENTITY của ChatMessage
       → MessageContent → parseMessageSegments → SelectionArea → MarkdownBody
       → ```chart fence → ChartSpec.parse → MessageChart (CustomPaint)
       → media → InlineImage / InlineVideo (media_kit) / InlineAudio

[14] _announceTurn → notificationIsWorthIt(appFocused, userIsLookingAtIt) = !(both)
       → DesktopNotification(opens: conversation.id) → click → revealChat()
```

---

## 9. Design system

`lib/shared/theme/app_theme.dart` (1354 dòng) là **toàn bộ** hệ thống.
Spec canonical: `docs/design-system.md`.

### Bốn quy tắc bất khả xâm phạm (§0)

1. **Không viền. Chiều sâu đến từ fill + shadow.**
2. **Label nằm trên field, không bao giờ float.**
3. **Thang bo góc 14 / 12 / 8 / 6 — hộp con không bao giờ tròn hơn hộp cha.**
4. **Mọi widget đọc color token phải tự gọi `AppTheme.watch(context)`.**

> Lý do quy tắc 1 *hoạt động được*: tương phản giữa các bề mặt là không đáng kể
> (dark `panelBg` vs `cardBg` = **1.105:1**; light `panelBg` vs `surfaceFill` = **1.053:1**).
> Một khối chỉ đổi `color` mà không có `AppGlass.cardShadow` thì **thực tế vô hình** —
> bỏ viền thì *bắt buộc* phải có shadow bù vào.

### Năm họ token

| Họ | Dùng cho | Ví dụ (light / dark) |
|---|---|---|
| `AppPalette` | Màu nền tảng | `windowBg` #FFFFFF / #0A0A0A · `panelBg` #F9F9F8 / #141414 · `cardBg` #F3F3F2 / #1E1E1E |
| `AppSurface` | Chrome overlay (đa số **translucent**) | `hoverFill`, `selectedFill`, `accentWash`, `recess`, `scrollThumb` |
| `AppGlass` | Bề mặt **nổi** | `surfaceFill` #FFFFFF / #202020 · `bubbleFill` · `rowFill` · `cardShadow` |
| `AppCard` | Công thức card | `base`, `inset`, `radius`=12, `insetRadius`=8, `heroShadow` |
| `AppControl` | Kích thước control | `height`=32, `radius`=8, `menuRadius`=6, `fontSize`=13, `menuMaxHeight`=240 |

### Cơ chế `AppTheme.watch` — vì sao cần

App đầy `const AppSidebar()`, `const _MainShellBody()`. Một `const` child là reference-identical qua các
lần rebuild của cha → Flutter short-circuit, **rebuild từ root không bao giờ với tới sidebar**.
Trường hợp thứ hai: item của `ListView.builder` được giữ nguyên qua rebuild của list
(`ChatBubble` từng làm cả transcript kẹt palette cũ).

Giải pháp: `_BrightnessScope` + `_FontScope` là `InheritedNotifier` — đánh dấu dependent bẩn **trực tiếp**,
xuyên qua mọi `const` boundary. **Hiện có 486 call site** `AppTheme.watch` trong `lib/`
(đo 2026-08-10; `design-system.md` ghi 186 — đã lạc hậu hai lần).

**Audit nhanh:** đếm số lần đọc token vs số `AppTheme.watch` trong một module — reads > 0 mà watch == 0
là bug flip theme chắc chắn.

### Bẫy đã ghim bằng comment

- **`windowBg` là nền *trang*, không phải mặt khối nổi.** Dark `#0A0A0A` **tối hơn** panel `#141414` và
  card `#1E1E1E` → dialog lấy `windowBg` sẽ *chìm xuống dưới* nền. Light thì lỗi này **vô hình**
- **Nâng nền khối cha thì phải hạ nền field con.** `LabeledField` mặc định fill `cardBg`; đặt trên dialog
  đã nâng (`#202020` dark) chỉ còn **1.023:1** → truyền `fill: AppCard.inset` (1.09:1).
  Light thì ngược lại → chọn theo brightness
- **Hai token accent đừng lẫn.** `AppPalette.accent` `#2F5BEA` **chỉ** làm fill dưới chữ trắng
  (trên nền tối chỉ 2.6:1). Chữ/icon accent dùng `accentOnSurface` (`#6E8BFF` dark, 4.65:1)
- **`colorScheme.onError` KHÔNG được set** → rơi về mặc định Material, chỉ **3.83:1** trên `error` dark.
  Nút màu → **đo chữ trên nền đó**, đừng tin token `on*`
- **`AppGlass.rowFill` ≠ `surfaceFill`.** Ở light `windowBg` là `#FFFFFF` và `surfaceFill` cũng vậy →
  row và trang ở **1.000:1**. Không thể nâng khối trên trang trắng tinh → light **recess**, dark **lift**
- **`'SF Mono'` KHÔNG resolve được trong CoreText** — trả nil, Flutter im lặng rơi xuống Menlo.
  Chỉ với tới được qua tên nội bộ `.AppleSystemUIFontMonospaced`
- **Menu tự tính vị trí bằng cách cộng chiều cao row của chính nó** — đổi padding mà quên sửa hằng số
  `_menuSize` là menu trôi khỏi nút

### Ba luật xác minh (đã học bằng bug)

1. **Màu và hình học thì TÍNH, đừng nhìn screenshot.** Ảnh nén/scale/đổi color profile làm chết chi tiết
   mảnh — đã báo động giả ba lần. Token có alpha phải **composite** đúng thứ tự lớp rồi mới tính WCAG.
   "Đo" hình học nghĩa là `tester.getRect()`, **không phải đọc code rồi suy luận**
2. **Hành vi nền tảng thì XEM APP THẬT.** Test headless báo PASS cho font/focus/selection đang hỏng thật
   (font manager của test resolve mọi family về cùng một test face). **Test vs ảnh mâu thuẫn → tin ảnh**
3. **Đổi UI thì kiểm CẢ light lẫn dark.** Light thường tha thứ, dark thì không

### Ba widget Material **không bao giờ** dùng thô

`Card()` (→ `AppGlass.surfaceFill` + `cardShadow` radius 14) · `DropdownButtonFormField`
(→ `AppSelectField`) · `MenuItemButton` (app không có `menuButtonTheme` → hand-roll menu row).

### Hover — hai vế, ai hover thì người đó giữ state

- **Row-hover** trả lời "hiện nút ra"; **button-hover** trả lời "con trỏ đang trên nút"
- Hover của cha **không** truyền xuống con. Nút phải tự bắt hover của chính mình
  (`MouseRegion`/`InkWell.onHover` + `setState`). Một `IconButton` trần bỏ qua chuyện này
- Row nằm trên nền đã có wash rồi thì màu thôi chưa đủ — nút cần **cả fill riêng** (radius 7)

---

## 10. Trạng thái hoàn thiện

| Feature | Trạng thái | Bằng chứng |
|---|---|---|
| Chat + agent (3 runtime) | ✅ **Shipped** | Đầy đủ, controller 579 dòng + 4 module, resume/queue/goal/plan |
| **Panel quanh chat** | ✅ **Shipped** | 2 host × 3 feature, tab strip, kéo seam, expanded; hình học là hàm thuần — nhưng `resolvePanelSizes` **chưa có test** (§13) |
| **Review** | ✅ **Shipped** | 6 scope, stage/commit/push, comment dòng, AI commit message, split/unified |
| **Terminal** | ✅ **Shipped** | pty thật, scrollback 10k, gắn được vào tin nhắn |
| **Files** | ✅ **Shipped** | Cây + breadcrumb + viewer, Markdown 2 dạng, "Add to chat" |
| **Git (cài/adopt)** | ✅ Shipped | Background install + Settings ▸ Coding ▸ Git |
| Skills | ✅ Shipped | 3 bug đã tìm ra (§7.4), "Draft with AI" tắt cứng (`_showAiDraft = false`) |
| Connectors (gateway + DCR) | ✅ Shipped | `rest_entry_fallback.dart` là scaffolding chờ gateway |
| Scheduled tasks | ✅ Shipped | Ghim model qua Python nội bộ Hermes (`TODO(BE)`) |
| Projects | ✅ Shipped | |
| Grid / network / members | ✅ Shipped | Member admin cho provider "BE support pending" |
| Provider node (local/external/API) | ✅ Shipped | Log engine chỉ dev build |
| Models | ⚠️ **Partial** | 4 hồi quy do split view thay UI cũ (§7.10) |
| Playground | ✅ Shipped | Responses path không stream |
| Auto router | ✅ Shipped | |
| Appearance | ⚠️ Partial | Font picker **chỉ hoạt động trên macOS** |
| Messages | 🔒 **devOnly** | Config writer đầy đủ; pin toolset đã gỡ (rủi ro bảo mật, §7.7) |
| Plugins | 🔒 **devOnly** | Codex plane null vĩnh viễn |
| Grids (tab) | 🔒 devOnly | |
| Debug | 🔒 devOnly | |
| Media / ComfyUI | ❌ **Tắt bằng cờ** | `kMediaSetupEnabled = false` |
| Browse connectors dialog | ❌ Tắt bằng cờ | `kShowBrowseConnectors = false` |
| **Overlord** | ❌ **FAKE + UNREACHABLE** | `FakeOverlordRepository` hardcode; 0 route; 1.417 dòng dead |
| Composio | ❌ **Chưa có 1 dòng Dart** | Doc `composio-proxy-contract.vi.md` nói "app đã implement xong" — **sai** |
| Windows auto-update | ❌ Hoãn | `isSupported => Platform.isMacOS` |
| `GridResolver.configuredPath` | ❌ Chưa nối UI | `providers.dart:16` tạo `GridResolver()` trần |
| Agent switcher (Skills/Connectors/Plugins) | ❌ Chưa có | `extensionAgentProvider` **luôn** trả `hermes` |
| Approval cho Codex/Claude | ❌ **Không có kênh** | `TODO(BE)` — cả hai chạy full access |

---

## 11. Invariant quan trọng nhất

Danh sách này là những thứ **mỗi cái từng là một bug thật**. Sửa ngược là tái tạo bug.

### Bảo mật / an toàn

1. **Secret chỉ đi qua kênh `environment`, không bao giờ vào argv.** Log chỉ ghi *tên* biến;
   header `Authorization` không bao giờ được ghi
2. **`ConnectorBridge` không xác thực gì** — rào duy nhất là bind loopback-only
3. **Codex/Claude chạy full access, không hỏi ai.** `ApprovalPicker` **chỉ chi phối Hermes**
4. **Allowlist bot Telegram/Discord/Slack là ranh giới bảo mật**, không phải tiện ích — pin toolset đã gỡ
5. **Refresh token thất bại KHÔNG BAO GIỜ xoá gì** — `refresh_token` là thứ duy nhất còn cứu được
6. **`ready` từ `/poll` chỉ đến một lần** → ghi đĩa trước mọi thứ, xác nhận bằng **đọc lại**

### Vòng đời process

7. **Cần CẢ `onWindowClose` VÀ `didRequestAppExit`** — `setPreventClose` không phủ ⌘Q
8. **`grid leave` cố ý không mang `--engine`** ở remote mode
9. **`resetAgentFeed()` phải chạy đồng bộ, trước mọi `await`**
10. **`slot.seen++` / `live.seen++` chỉ khi turn thành công**
11. **`StdioLineWriter` xếp hàng chứ không ghi thẳng** — `IOSink.flush()` *bind* sink; một write chen giữa
    ném và **mất luôn dòng đó** (đã treo Hermes gần 6 phút)
12. **Đóng tab panel phải `endSession(tabId)`** — pty mồ côi là process user không còn thấy để mà dừng.
    Gọi từ `PanelTabs.close()`, **không** từ watcher (watcher chỉ chạy khi có người nhìn)
13. **Kill shell bằng `SIGHUP`** (Windows: `SIGTERM`) — `SIGTERM` để lại con của shell ôm một pty không
    ai đọc
14. **`git` chạy với `GIT_TERMINAL_PROMPT=0` + `ssh -o BatchMode=yes`** — app không có terminal, prompt
    không ai trả lời được là treo tới hết timeout
15. **macOS: không bao giờ exec `/usr/bin/git`** — nó là stub `xcode-select`, chạy nó **bật installer của
    Apple**; resolve qua `xcode-select -p` rồi dùng đường tuyệt đối

### Dữ liệu

16. **`archivedAt` dùng `_parseNullableDate`**, không `_parseDate` (fallback epoch)
17. **`copyWith` không unset được bằng `?? this.x`** → cần cờ `clearArchivedAt`, `clearGoal`,
    `clearUiFontFamily`, `clearCategory`…
18. **Mọi thứ đọc lịch sử chat dùng `state.live`**, không `.conversations`
19. **`saveRefreshed` merge, không assign**
20. **`null` ≠ `ConnectorTransport.none`**; **`advertises_*` là tri-state**, `null` ≠ `false`
21. **`served` rỗng = "chưa load"**, không phải "grid không phục vụ gì"

### Riverpod / render

22. **`gridOverviewSnapshot` là cửa duy nhất** — `.asData` làm số về 0 mỗi poll; watch cả `AsyncValue` +
    family trong cùng body → `setState() during build`
23. **Value equality của `GridOverview` là load-bearing**
24. **`routeFor` nhận `GridOverview?`, không `AsyncValue`**
25. **`CommandLogNotifier._schedule` = `Future.microtask`** là bắt buộc, không phải tối ưu
26. **Mọi widget đọc token phải tự `AppTheme.watch(context)`**

### Wire protocol

27. **`ChatSendStreaming.text` là TOÀN VĂN; `ChatDelta.text` là mảnh.** Hermes message là **delta**;
    Claude/Codex là **toàn văn**
28. **`--mcp-config` bắt buộc đi kèm `--strict-mcp-config`**; write hỏng → `null` → bỏ **cả hai**
29. **`codex exec resume` không nhận `--sandbox` và `-C`**, nhưng `-c` overrides phải đi trên **mọi** lượt
30. **`Accept: application/json, text/event-stream`** bắt buộc cả hai (Canva trả 406)
31. **SSE lấy `data:` CUỐI CÙNG**, không phải đầu
32. **`CliResult.sessionExpired` là string-match trên 4 câu tiếng Anh** — CLI đổi wording là app im lặng
    ngừng phát hiện

---

## 12. Chạy, build, release

### Dev

```bash
export PATH="$HOME/WorkPlace/Flutter/flutter/bin:$PATH"
cd autonomous-grid-app && flutter pub get && flutter run -d macos
```

CLI phải resolve được trước:

```bash
cd ../autonomous-grid && uv tool install -e . --force   # → ~/.local/bin/grid
```

> **Gotcha:** `uv tool install -e .` đóng băng version metadata lúc cài, nên sau khi đổi branch CLI thì
> `grid --version` vẫn báo số cũ cho tới khi `uv tool install -e . --force --reinstall`.

> **Sidecar thắng `$PATH`.** Bản packaged luôn dùng `grid` bên trong `Grid.app` dù bạn vừa cài bản mới.
> Dùng `GRID_BIN`, hoặc re-inject bằng `scripts/bundle_grid_macos.sh`.

CocoaPods bắt buộc (`/opt/homebrew/bin/pod`); prepend `/opt/homebrew/bin` vào PATH, set `LANG=en_US.UTF-8`.

### Gate trước khi "done"

```bash
flutter analyze lib test        # mục tiêu 0 issue
flutter test test/<area>        # logic test — KHÔNG viết widget test mới
dart format .
```

Đo lại trên `main` sạch **2026-08-10**: **0 issue**, **2351 test pass / 0 fail** (06/08: 2122).
Cả hai bar đều sạch, nên một failure bạn thấy là của bạn. (Nợ cũ — 9 issue trong `models/` và 3 widget
test overflow ở `connectors_view_layout_test` — đã dọn ở `8b5c5ac`: file test kia xoá cùng widget, đúng
cách §8 conventions nói về "rot".)

### Build & release

```bash
./scripts/bundle_grid_macos.sh     # build app + inject Nuitka onefile sidecar
./scripts/package_dmg_macos.sh     # DMG ad-hoc
DEV_ID="…" NOTARY_PROFILE=grid-notary ./scripts/notarize_macos.sh
```

Push tag `v*` → `.github/workflows/release.yml` → draft release với
`Grid-<ver>-macOS-Apple-Silicon.dmg` + `Grid-<ver>-macOS-Intel.dmg` (đều signed + notarized).
Windows job đang comment cho tới khi có code-signing.

**Runtime không bundle:** `llama-server` (`grid engine install llama.cpp`),
ComfyUI (`grid media install`). Provider node target **macOS Apple Silicon** và **Linux NVIDIA**;
trên Windows app effectively consumer/playground only.

---

## 13. Nợ kỹ thuật

### Vi phạm chiều phụ thuộc (§1 conventions: `presentation → logic → infrastructure`, không ngược)

| Từ | Tới |
|---|---|
| `infrastructure/api/connector_gateway_client.dart` | `features/auth`, `features/agents`, `features/connectors` |
| `infrastructure/cli/hermes_cron_service.dart` | `features/agents/logic/agent_plugin.dart` |
| `shared/widgets/choice_row.dart`, `step_row.dart` | `features/provider_node/presentation/engine_block.dart` |
| `shared/widgets/modality_mark.dart` | `features/playground/logic/*` |
| `features/provider_node/presentation/add_engine_options.dart` | `features/models/presentation/*`, `features/node_setup/*` |
| `features/agents/logic/adapters/*_extensions.dart` | `features/skills/logic/skill_author.dart` |
| `features/overlord/**` | `features/network/presentation/detail_widgets.dart` (`copyToClipboard`) |

`EngineSurface`, `PlaygroundModality`, `copyToClipboard` đáng lẽ phải nằm ở `shared/`.

> **Nguyên nhân gốc của 9 chỗ `infrastructure/ → features/`: model dữ liệu của connector và agent nằm
> nhầm tầng.** `ConnectorToken`, `RestEntry`, `McpServer`, `AgentPlugin`, `CronRunError`,
> `hermesPathProvider` đều là kiểu **hạ tầng thuần** nhưng bị đặt trong `features/`.
> Sửa = chuyển 6 file model xuống `infrastructure/` hoặc `core/` — **không cần đổi một dòng logic nào**.

Ngoại lệ hợp lệ, **giờ có hai**: `shared/layouts/widgets/section_view.dart` import 15 view, và
`features/chat/presentation/panel_feature_view.dart` import `presentation/` của review/files/terminal.
Cả hai **là bảng ánh xạ** — một bảng ánh xạ buộc phải gọi tên cả hai phía. Điều giữ ngoại lệ khỏi lan
ra là **giới hạn nó trong đúng một file**: không thứ gì khác trong `chat/` biết các class đó tồn tại.

**Các domain mới sạch hơn phần còn lại của repo:**

| Domain | Import ra ngoài |
|---|---|
| `terminal/`, `git/` | chỉ `infrastructure/` + `shared/` — **0 cross-feature** |
| `review/` | `playground/logic/{chat_transport, one_shot_target}` (viết commit message), `projects/logic/project.dart` |
| `files/` | `chat/logic/workspace_browser.dart` (3 chỗ) |

Hai cạnh cuối là **nợ mới, cùng một dạng cũ**: `ChatTransport`/`resolveOneShotTarget` là hạ tầng "gọi một
phát tới model" (skill generator cũng dùng), và `workspace_browser` là code duyệt thư mục — **cả hai đáng
lẽ nằm ở `shared/` hoặc `infrastructure/`**, không phải trong `playground/` và `chat/`. Sửa = chuyển file,
không đổi logic.

### Chu trình import feature ⇄ feature (Dart cho phép, nhưng mỗi cái là một biên đã mất)

| Cặp | Bằng chứng | Mức |
|---|---|---|
| `chat` ⇄ `projects` | `chat_sessions_controller.dart:21` ↔ `projects_view.dart:7` | logic ⇄ logic |
| `chat` ⇄ `scheduled` | `task_delivery.dart:12` ghi **thẳng vào state chat** ↔ `chat_history_list.dart:16,17` | logic ⇄ logic |
| `agents` ⇄ `skills` | 3 `*_extensions.dart` → `skill_author.dart` ↔ 10 file skills → agents | logic ⇄ logic |
| `auth` ⇄ `provider_node` | `auth_controller.dart:7` (gọi `shutdownServing()` khi logout) ↔ 4 import ngược | logic ⇄ logic |
| `auth` → `network/presentation` | `browser_fallback.dart:5` → `detail_widgets.dart` | **presentation cross-feature** |
| `chat` ⇄ `terminal` | `panel_tabs.dart:5` + `composer_context.dart:5,6` ↔ `terminal_session` không import ngược | logic → logic, **một chiều** |
| `chat` ← `files` | `files_filter.dart:6` + 2 widget → `chat/logic/workspace_browser.dart` | logic ⇄ logic |

Cặp `chat` ⇄ `terminal` là **một chiều** và cố ý: `terminal/` không biết panel là gì
(*"a terminal has no business knowing what a panel is"*), nên `chat/` gọi `endSession` chứ không phải
ngược lại. Đó là hình dạng đúng — chỉ thiếu bước cuối là đưa `TerminalCapture` xuống `shared/`.

### Kiểu choke-point — đổi là gãy nhiều chỗ

| Type | Ở đâu | Tính chất mỏng manh |
|---|---|---|
| `GridCliService` (3 method) | `cli/grid_cli_service.dart:76` | 28 call site, 1 điểm dựng. `sessionExpired` là **string-match 4 câu tiếng Anh** |
| `ChatSendUpdate` (sealed 5) | `playground/logic/chat_sender.dart:23` | Điểm hợp nhất của **cả 4 nhánh** gửi tin |
| `Conversation` | `chat/logic/conversation.dart:10` | 6 domain đọc; `archivedAt` timestamp; cần cờ `clear*` |
| `NetworkCredential` | `state/models/network_credential.dart` | 3 trục quyền khác nhau; `isPublic` **cố ý đảo** |
| `ConnectorToken` + `McpEntry` + `RestEntry` | `agents/logic/` | Type duy nhất đi xuyên **cả ba plane** |
| `AgentExtensions` (3 plane) | `agents/logic/agent_extensions.dart` | **Null-plane là câu trả lời hợp lệ**, không phải lỗi |

### Hàm thuần tự nhận là "để test được" nhưng **chưa có test**

§8 conventions: *"pure logic (parsing, deriving, planning) sống trong hàm không side-effect **và được
unit test**"*. Ba hàm dưới đây có doc comment tự biện minh cho việc chúng thuần **bằng chính lý do
testability** — rồi không ai viết test:

| Hàm | Doc comment nói | Test |
|---|---|---|
| `resolvePanelSizes` (`chat/logic/panel_layout.dart`) | *"Pure, and out of `build` on purpose: bốn clamp phải nhất quán với nhau"* | **0** |
| `decodeFilePreview` (`files/logic/file_preview.dart`) | *"Pure, so ba phán đoán này test được mà không cần filesystem"* | **0** |
| `filePathCrumbs` (`files/logic/files_path.dart`) | — | **0** |

`resolvePanelSizes` là cái đắt nhất trong ba: nó chi phối **mọi** kích thước của pane, và chính comment
của `kChatMinWidth` kể lại rằng lần đo trước **đã ship sọc tràn lên composer thật**. Hàng xóm của nó
(`resolvePanelSideWidth`, `tabStripTabWidth`) thì **có** test — nên khoảng trống này là bỏ sót, không
phải một quyết định.

### Điểm mù quan sát

**Chỉ 6 file** phát `CliCallKind.http` (3 network controller, `grid_overview_provider`, `member_providers`,
`network_models_provider`, `playground/chat_sender`, `skills/skill_generator`). Nghĩa là **không** hiện ở
tab Debug lẫn `app_https-*.log`:

- toàn bộ `ConnectorGatewayClient` (OAuth broker — chỉ ghi `appLogProvider`)
- `ModelCatalogClient` — **không ghi ở đâu cả**
- `SmitheryRegistryClient`
- `McpProxy` / `RestInvoker` — **tool call thật của agent**
- toàn bộ HTTP do `claude`/`codex`/`hermes` tự bắn

> Khi user báo "connector không hoạt động" hoặc "agent gọi tool lỗi", **transcript HTTP trên đĩa không
> chứa gì cả.** Phải debug bằng `appLog`.

### Số đo hiện trạng (2026-08-10)

`flutter analyze lib test` → **0 issue**. `flutter test` → **2351 pass, 0 fail**.
**259 file test**, trong đó **24 file còn `testWidgets`** (legacy — §8 conventions cấm thêm mới;
con số **không tăng** dù `lib/` phình 15.000 dòng, tức luật đang được giữ).
**26 `TODO` trong `lib/`, 20 trong đó là `TODO(BE)`** (chờ backend).
`AppTheme.watch`: **486 call site**.
Gateway connector đo 2026-08-05: **12 row, tất cả `auth_type: app`, 8/12 có `mcp_url`, 8/12 trả
`description: ""`** (nên `connector_blurb_fallback.dart` tồn tại).

| | 06/08 | 10/08 |
|---|---|---|
| File Dart trong `lib/` | 558 | **668** |
| Dòng | ~105.000 | **~120.900** |
| Feature domain | 23 | **26** |
| Test pass | 2122 | **2351** |
| `AppTheme.watch` | 399 | **486** |

> Đo lại trước khi trích bất kỳ số nào ở đây. Bảng này đã lạc hậu **hai lần trong bốn ngày**.

### Dead code đo được (đo lại 2026-08-10 — danh sách **không đổi**)

`overlord/**` (**1.417 dòng**, unreachable) · `models/presentation/{download_row,manager_search_field}.dart`
(0 import; `suggested_models_section.dart` đã xoá ở `8b5c5ac`) · `model_shelf.dart::buildModelShelf` ·
`catalogModelsProvider` (chỉ còn chính định nghĩa của nó) ·
`shared/layouts/widgets/{hosting_summary,plan_type_pill}.dart` (0 call site) ·
`shared/widgets/{pulse.dart::PulseDot, coming_soon_view.dart, not_yet_badge.dart}` — hai cái sau chết
**thành cặp**: `coming_soon_view` là call site duy nhất của `NotYetBadge` ·
`conversation.dart::groupConversationsByRecency` · `parsers/{member_entry,denylist_entry}.dart` ·
`api/models/chat_chunk.dart` · `run(timeout:)` (không call site nào truyền) ·
`snackBarTheme` (SnackBar bị cấm, 0 call site).

⚠️ **`skill_generator.dart` đã đổi trạng thái** — không còn "0 import". `new_skill_dialog.dart` giờ gọi
`skillGeneratorProvider`, nhưng **gate là một hằng `final bool _showAiDraft = false`** ở cuối chính file
dialog đó. Tức nó *biên dịch vào bundle, có call site, và không đường nào tới được*. Dạng dead code này
khó thấy hơn dạng cũ: grep "0 import" **không bắt được nó nữa**.

### Nợ design-system (đo lại 2026-08-10)

| Vi phạm | Số chỗ | So với 06/08 |
|---|---|---|
| `IconButton` trần | **41** | = |
| `backgroundColor: AppPalette.windowBg` (dialog chìm ở dark) | **7** — `login_screen`, `project_instructions_dialog`, `create_project_dialog`, `agent_changes_bar`, `prompt_dialog`, `onboarding_page`, `home_shell` | = |
| `MenuItemButton` trần | **3** — `approval_picker`, `agent_picker`, `task_power_bar` | = |
| `CircularProgressIndicator` trần | **5** — đều trong `models/` (`model_detail_panel` 3, `model_manager_split` 2). 4 chỗ còn lại nằm trong chính `AppSpinner`, hợp lệ | = |
| `Card()` Material | **1** — `node_setup_card.dart:51` | = |
| `DropdownButtonFormField` / `InputDecoration(labelText:)` / `SnackBar` | **0** ✅ | = |

> **15.000 dòng mới không thêm một vi phạm nào vào bảng này.** Đó là kết quả đáng chú ý nhất của lần đo
> lại: `review/`, `files/`, `terminal/` dựng menu và spinner theo đúng công thức.

#### Nợ MỚI: công thức menu row bị chép tay **bảy** lần

Design system §5 mô tả một "menu row chuẩn", nhưng `shared/` **không cung cấp widget nào cho nó**. Hệ quả:
mỗi feature cần menu lại tự dựng lại — `chat_header.dart:_ChatMenuItem` (bản tham chiếu đã đo bằng test),
`panel_feature_menu.dart:_FeatureMenuItem`, `project_menu.dart:_ProjectMenuItem`,
`skill_menu.dart:SkillMenuItem`, `archived_chats_view.dart:_FilterMenuRow`, và **hai cái mới**:
`review/presentation/widgets/menu_row.dart` (297 dòng, có cả `MenuRowBody` + `MenuRowChevron`) và
`files/presentation/widgets/files_menu_row.dart`.

Cả bảy đều **đúng** hôm nay, và doc comment của mỗi cái đều giải thích lại cùng một lý do (Material sai
4 điểm: radius 0, text 14pt, hover xám `onSurface`, có ripple). Nhưng bảy bản sao của một công thức là
bảy chỗ để nó trôi khỏi nhau — và luật "hai màn hỏi cùng một câu thì dùng chung widget và chung chữ"
(§5 conventions) đang bị vi phạm ở đúng chỗ khó thấy nhất.

**Sửa:** một `AppMenuRow` ở `shared/widgets/`, dựng từ `_ChatMenuItem`. `review/menu_row.dart` đã là bản
đầy đủ nhất (có chevron cho submenu) nên nó là ứng viên tốt nhất để nâng lên.

Thêm, **trong chính `shared/`**:
- `appMenuStyle()` hardcode radius **10** trong khi `AppControl.menuRadius = 6` → ba loại menu lệch 6/6/10
- Hai màu menu fill song song: theme set `#1E1E1E`, `appMenuFill()` trả `#2A2A2A`.
  Một `MenuAnchor` **không** truyền `appMenuStyle()` sẽ lấy `#1E1E1E` — chỉ 1.023:1 so với
  `surfaceFill`, panel **không có cạnh**
- `AppMotion` chưa được tôn trọng: ~8 chỗ hardcode duration
- `LogView` hardcode `#1E1E1E`/`#D4D4D4`, không theme-aware

### Tài liệu đã lỗi thời

| File | Sai chỗ nào |
|---|---|
| `README.md` | Nói Provider/Models gate theo role — thực tế gate theo `devOnly × build mode`. Trỏ tới 3 file `docs/` **không tồn tại** |
| `docs/OVERVIEW.md` | Viết 14/7 — thiếu 5 domain; §8.10 mô tả API skill đã bị xoá |
| `docs/messages-tab.md` §5 | Mô tả `_restrict()` ghim toolset — code làm **ngược lại** (unpin) |
| `docs/features/connectors/composio-proxy-contract.vi.md` | Nói "app đã implement xong và đang chờ" — **0 dòng Dart nhắc tới Composio** |
| `docs/features/connectors/gateway-api-for-grid-desktop.md` | Mô tả hợp đồng khác hẳn cái đang chạy (D12 supersede D9) |
| `docs/design-system.md` | Ghi 186 call site `AppTheme.watch` (thực tế **486**); xếp `surfaceFill`/`sidebarFill` vào `AppSurface` (thực tế `AppGlass`); §4 ghi `w600` (thực tế `w500`). **Chưa nói gì về panel** — `PanelBody`, `PanelSplitter`, `PanelToggle`, chiều cao toolbar 36px và thang tab 96–180px đều là hình học chuẩn giờ đã có nhưng không nằm trong spec |

### `TODO(BE)` — chờ backend

- Relay **không quảng cáo context window** (`context_length: null`) → app phải *học* từ lỗi engine
- Gateway chưa ship `rest_entry` → `rest_entry_fallback.dart` (445 dòng) là scaffolding chờ xoá
- Gateway chưa ship `description` → `connector_blurb_fallback.dart` (9 mô tả stand-in)
- Endpoint rename grid **không validate gì** (khác hẳn create)
- `hermes cron create/edit` thiếu `--model`/`--provider`/`--toolsets`
- `agent_release_pins.dart` là **bản sao tay** của installer trong CLI Python — CLI bump version mà quên
  bump ở đây ⇒ hash không khớp ⇒ **mọi** install fail. Đề xuất `grid agent spec --json`
- `kHermesAcpRequirement = 'hermes-agent[acp,mcp]'` nhưng installer của CLI vẫn chỉ xin `[acp]`
  → `grid agent install` từ terminal dựng env **không có MCP SDK**, mọi connector chết im lặng
- Approval per-action cho Codex và Claude Code

---

## Tài liệu liên quan

- [`docs/design-system.md`](design-system.md) — **spec canonical** cho UI, đọc trước khi style bất cứ thứ gì
- [`docs/conventions.md`](conventions.md) — architecture, Riverpod rules, Dart style, copy rules, testing policy
- [`docs/style-guide-grid-app.md`](style-guide-grid-app.md)
- [`docs/git-auto-install.md`](git-auto-install.md) — chi tiết probe/tải/adopt Git (§4.6, §7.25)
- [`docs/messages-tab.md`](messages-tab.md) — ⚠️ §5 đã lỗi thời
- [`docs/OVERVIEW.md`](OVERVIEW.md) — handover 14/7, còn đúng ở phần build/release
- [`scripts/README.md`](../scripts/README.md) — sidecar bundling, signing, packaging
