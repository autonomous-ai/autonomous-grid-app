# Codex → chat: how the app-server stream is read and drawn

State: **2026-09-10**. Grid pins `codex-cli 0.144.6`. Reference studied: Codex's
own VS Code extension **`openai.chatgpt` 26.903.71938**, which bundles
`codex-cli 0.153.4` (`~/.vscode/extensions/openai.chatgpt-*/`). Tracked with
the code, whose library docs carry the same map — change both together. The
Claude lane's twin is [claude-rendering.md](claude-rendering.md).

---

## 1. Pipeline (Grid)

```
codex app-server           JSON-RPC over stdio — the same transport the
  │                        extension spawns (`-c features.code_mode_host=true
  │                        app-server --analytics-default-enabled`)
  ▼
CodexAppServerService      _onNotification → events; _onServerRequest →
  │                        approvals (codex_approval.dart)
  ▼
parseCodexAppServerEvent   method switch; thread ownership (a helper's
  │                        notifications nest under the spawn, never end the
  │                        turn); returns a LIST — a patch is several events
  ▼
parseCodexAppServerItem    ThreadItem switch (codex_app_server_items.dart)
  ├── codexCommandActivity   commandExecution → row named by commandActions
  ├── codexFileChangeEvents  fileChange → a row per file (+ diff) and, once
  │                          landed, CodexFileChangeEvent for open/undo
  └── codex_app_server_rows  collab, notes, MCP (connectorLabel), web search
  ▼
CodexEvent (sealed) → codex_chat_sender → AgentRuns → AgentTurnView/_StepRow
```

## 2. Extension ↔ Grid

The webview bundle is `webview/assets/app-initial-*.js` (several builds; the
item switch is in the one with the most `commandExecution` hits). Minified names
change; grep the anchors.

| Extension piece | Anchor | What it does | Grid |
|---|---|---|---|
| Host spawn | `Spawning codex app-server` (out/extension.js) | one app-server per window | `CodexAppServerService` (one per turn) |
| Item → view entries | `` case`commandExecution`:{if(m?.fits( `` | switch over `ThreadItem.type` | `parseCodexAppServerItem` |
| Command actions `cy()` | `` case`listFiles`:return{type:`list_files` `` | `read`/`listFiles`/`search`/`unknown` → one **exec entry per action**; `declined` falls back to the raw command | `codex_command_actions.dart`: **one row per command**, named by its actions when they all agree |
| File changes `ly()` / `oy()` | `` move_path:r.move_path??null ``, `` diff --git a/${n} `` | `changes[]` → `{add: content, update: unified_diff, delete}`; headers added when missing | `codex_file_changes.dart`: a row per file, diff behind the fold |
| Edited paths | `` n.kind.type===`update`?n.kind.move_path??n.path `` | `kind` is an **object** | `codexChangeKind` reads object *and* legacy string |
| Turn diff | `` type:`turn-diff` `` | one card with every change of the turn | not copied (rows per file) |
| Reasoning `vy()` | `` t.startsWith(`**`) `` | first summary line bolded as a header | note row behind the fold |
| Proposed plan | `` type:`proposed-plan` `` | the `plan` item | note row; `turn/plan/updated` → `CodexPlanEvent` |
| Approvals | `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` | card | `codex_approval.dart` |

## 3. ThreadItem types

`codex app-server generate-json-schema --out DIR` prints the protocol of the
binary you run — the source of truth. 0.144.6 has 18 item types; 0.153.4 adds
`functionCallOutput` (unhandled → no row, tolerated).

| Type | Row |
|---|---|
| `agentMessage` | the answer (a helper's → note under its spawn) |
| `reasoning` / `plan` | note row (thinking) |
| `commandExecution` | `Read · a.dart` / `Search · q in lib` / `List · lib` when every `commandAction` is that kind; else `Shell` + the command. Request = the command; result = `aggregatedOutput` |
| `fileChange` | `Edit · a.dart` (+ `→ b.dart` on a rename) with a unified diff; `Write · new.dart` with the file; `Delete · x`; then `CodexFileChangeEvent` on `completed` |
| `mcpToolCall` | `gitnexus · impact · ChatStore`, tool `mcp__gitnexus__impact`, result = the content blocks' text |
| `webSearch` | query / page opened / `"pattern" in url` from `action`; **no status field** — settled by `item/completed` |
| `dynamicToolCall`, `collabAgentToolCall`, `imageView`, `imageGeneration`, `sleep`, `enteredReviewMode`, `exitedReviewMode`, `contextCompaction` | rows as before |
| `userMessage`, `hookPrompt`, `subAgentActivity` | none |

## 4. Measured (a month of `~/.codex/sessions`, originator `grid-app`)

- 1,105 `exec_command` calls — the bulk of Codex's work here; 1,093 compound,
  1,003 opening with `cd … &&`. Classified the way the parser reads them:
  169 pure reads, 14 searches, 9 listings (~1 in 6) now read as what they did.
- MCP calls ~45 (gitnexus, grid, chrome-devtools); web search 3; `apply_patch`
  rare on grid models (they edit through the shell).

## 5. Fixed on the way (all pre-existing)

- **`kind` object**: `codexChangeKind` switched on `'add'`/`'delete'` strings
  left over from `exec --json`; the app-server sends `{type: 'add'}`, so no
  created file was ever recorded for open/undo. Evidence: the pinned binary's
  own generated schema (`PatchChangeKind` oneOf objects) and the extension's
  `kind.type`. (Grid's logs don't record app-server items, so not seen on the
  wire here.)
- **Patches were invisible** in the feed (only the undo record was emitted).
- **Web searches never settled** — no `status` on the item.
- **MCP results** printed as Dart's `{content: [...]}`.
- **Connector titles** showed `mcp__server__tool` — in both lanes; the title is
  now the label's head (`gitnexus`, `Browser`).

## 6. Deliberate differences — don't "fix" them back

- **One row per command**, not per action: a Grid step is one call with one
  output, and the fold shows that output once.
- **Rows per file** rather than a turn-diff card: a row is where the step
  happened in the turn.
- **Reasoning stays behind the fold**, unbolded.

## 7. When Codex updates — checklist

1. Schemas for both builds:
   ```sh
   S=$(mktemp -d); codex app-server generate-json-schema --out $S/pinned
   ~/.vscode/extensions/openai.chatgpt-*/bin/macos-aarch64/codex app-server generate-json-schema --out $S/new
   ```
   Diff `ThreadItem` variants and their fields (python: read `definitions`
   across the files, list `oneOf[].properties.type.enum`).
2. New item type → a case in `parseCodexAppServerItem` (or deliberately none).
   New field on a known one → check what the extension does with it (anchors
   above).
3. `CommandAction` / `PatchChangeKind` / `WebSearchAction` changed? →
   `codex_command_actions.dart`, `codex_file_changes.dart`, `codexWebSearchSubject`.
4. New row words → `_kToolFamilies` / `_gerund` in `agent_step_label.dart`.
5. Tests: `test/agent/codex_agent_test.dart` — group "what a Codex step says,
   the way its own panel says it"; `test/agents/agent_step_label_test.dart`.
