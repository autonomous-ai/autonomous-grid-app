# Claude Code → chat: how the stream is read and drawn

State: **2026-09-10**, Claude Code 2.1.x. Reference studied: Claude's own VS Code
extension **2.1.266** (`~/.vscode/extensions/anthropic.claude-code-2.1.266-*`).
Tracked with the code, whose library docs carry the same map (`claude_tools.dart`,
`claude_content.dart`, `claude_task_list.dart`) — change both together.

The Claude lane of the chat is laid out **the way Claude's VS Code panel is**, so
a Claude Code release is followed by diffing its bundle against one list.

---

## 1. Pipeline (Grid)

```
claude -p --output-format stream-json --verbose --input-format stream-json
       --include-partial-messages                      (claudeExecArgs)
  │  NDJSON on stdout
  ▼
ClaudeExecService._onLine          LineSplitter → _tryDecode (non-JSON skipped)
  │                                control_* → permission (claude_permission.dart)
  ▼
ClaudeStreamParser.read            STATEFUL: type → events; a tool_result settles
  │                                its tool_use by id; sub-agents by parent id;
  │                                background tasks / wake-ups / crons
  ├── claudeTool(name)             per-tool: label, request, showsResult,
  │                                editsFiles              → claude_tools.dart
  └── claudeToolResult(content)    block → text, CLI wrapping removed
  │                                                        → claude_content.dart
  ▼
ClaudeExecEvent (sealed)           Activity · Message · Plan · Questions ·
  │                                FileWriteStarted/Finished · Turn*
  ▼
claude_chat_sender → AgentRuns.upsertStep → agentRunProvider(chatId)
  ▼
AgentTurnView → _StepRow           glyph: agentToolFamily   title/detail:
                                   agentStepTitle/Detail    fold wells:
                                   request (stepRequestLanguage) + result
```

The session importer (`parseClaudeSession`, `~/.claude/projects/**.jsonl`) reads
tool results with the same `claudeToolResult` and drops interrupt notes with
`isClaudeInterruptNote` — an imported step reads like a watched one.

## 2. Extension ↔ Grid, piece by piece

Minified names (`w2`, `DG`…) change every release; the **anchor** column is a
string that doesn't — grep it in `webview/index.js` (or `extension.js`).

| Extension piece | Anchor to grep | What it does | Grid |
|---|---|---|---|
| `ProcessTransport.readMessages` (extension.js) | `Non-JSON stdout` | readline over stdout, skip bad lines | `ClaudeExecService._onLine` + `_tryDecode` |
| SDK message → view message | `"tool_use_summary"` | only `user`/`assistant` become messages; `stream_event`, `system`, `result`… are side channels | `ClaudeStreamParser.read` switch |
| Stream assembler | `processStreamEvent`, `input_json_delta` | one assembler per `parent_tool_use_id`; patches deltas into blocks | `_readStreamEvent` (root `text_delta` only) |
| Reducer | `setToolResult` | `tool_result` attached to its `tool_use` by id (newest first); `tool_progress`; streamed msg replaced by final one (uuid / message id), timing kept | `_calls` + `AgentActivity.settled`; `_partial`/`_completed` |
| Content block wrapper | `toolResultSignal` | block + result + progress + start/end time | `AgentActivity` (+ `startedAt`) |
| Content-type dispatch | `Unsupported content type` | text / image / document / tool_use / tool_result / thinking / tool_reference | `_readAssistantBlock`, `_readUserBlock`, `claude_content._blockText` |
| Base tool renderer | `toOutputContent` | `header` · `renderInput` · `renderOutput` · `permissionRequest` · `hidden` | `ClaudeTool`: `label` · `request` · `showsResult` · `editsFiles` |
| Registry | `name==="Task"?"Agent"` | find by name → Chrome MCP → any MCP → generic | `claudeTool(name)` |
| One class per tool | `name="Bash"`, `name="WebFetch"`… | per-tool header/body | entries in `_kTools` |
| User-text parser | `ide_selection` | tags in a user turn → chips; interrupt sentinels | `isClaudeInterruptNote`, `stripInjectedContext` (import) |
| Message cap | `protectRecentFromToolPass` | 600 → 500 messages, finished tool pairs first | `storedParts` (120 steps), `kFoldedRun` |
| Status dot | `dotProgress` | no result + not busy → failure | `settledParts` → **unknown** (deliberate) |
| Markdown | `isPartialText` | withholds the in-flight paragraph | not copied — see §5 |

## 3. Tools (`claude_tools.dart`)

| Tool | kind | Row label | Fold request | Result | Edits files |
|---|---|---|---|---|---|
| `Bash` | command | `Bash · <command>` | bare command | shown | |
| `BashOutput`, `KillShell` | command | name | JSON | shown | |
| `Read` | tool | `Read · a.md (lines 490–569)` | JSON | shown | |
| `Edit` | tool | `Edit · a.dart` | **unified diff** (`--- p`/`+++ p`) | shown | ✓ |
| `Write` | tool | `Write · a.dart` | **file content** | shown | ✓ |
| `NotebookEdit` | tool | `NotebookEdit · x.ipynb` | JSON | shown | ✓ |
| `Glob`, `Grep` | tool | `· <pattern>` | JSON | shown | |
| `WebSearch` / `WebFetch` | web | `· <query>` / `· <url>` | JSON | shown | |
| `Agent`, `Task` | tool | `· <description>` | JSON | shown | |
| `Skill` | tool | `· <skill>` | JSON | shown | |
| `CronCreate` | tool | `· <cron>` | JSON | shown | |
| `ScheduleWakeup` | tool | `· in 60s · reason` / `· stop` | JSON | shown | |
| `ToolSearch` | tool | `· gitnexus impact, Monitor` | JSON | tool names | |
| `EnterPlanMode` | tool | "Planning before changing anything" | JSON | **hidden** | |
| `ExitPlanMode` | tool | "Finished the plan" | the plan (markdown) | **hidden** | |
| `mcp__claude-in-chrome__*`, `mcp__chrome-devtools__*` | web | `Browser · <action> · <url/query/…>` | JSON | shown | |
| `mcp__<server>__<tool>` | tool | `<server> · <tool> · <query/target/url/topic/repo>` | JSON | shown | |
| anything else | tool | `Name · <file_path basename>` | JSON | shown | |
| `TodoWrite` (VS Code lane only now) | — | not a row → `ClaudePlanEvent` (whole list) | | | |
| `TaskCreate` / `TaskUpdate` (the `-p` lane's plan: 256 / 334 calls a month, 0 `TodoWrite`) | — | not a row → the parser keeps the list (`_tasks`, numbered by the `Task #N created` result), seeded from the CLI's store on a resumed turn, and sends it whole on every change; `deleted` removes; sub-agents write into the same list | | | |
| `TaskList`, `TaskGet` | — | not a row (plan bookkeeping) | | | |
| `TaskOutput`, `TaskStop` | tool | ordinary rows — background work, not the plan | | | |
| `AskUserQuestion` | — | not a row → `ClaudeQuestionsEvent` (card) | | | |

The extension has no answer for the task tools (its lane still sends
`TodoWrite`), so their handling is Grid's own, built from the measured shapes:
`TaskCreate {subject, description, activeForm}`, `TaskUpdate {taskId, status}`
with status `completed` / `in_progress` / `deleted` / `pending`.

### The task list across turns

A turn is one process and one parser, but the task list is the **session's**.
The CLI stores it at `<CLAUDE_CONFIG_DIR or ~/.claude>/tasks/<list id>/<n>.json`
(`{id, subject, description, activeForm?, owner?, status, blocks, blockedBy}`,
plus `.lock` and `.highwatermark`; a deleted task's file is removed). The list
id is `CLAUDE_CODE_TASK_LIST_ID`, else the team, else the **session id** (CLI
function behind the anchor `"[Tasks] resetTaskList"`; 43/43 dirs here are named
after their session, `--resume` keeps the id, sub-agents write into the parent's).

The extension keeps its process alive and replays history (`loadFromMessages`)
to rebuild state; Grid reads the store instead: `ClaudeExecService.start` reads
`claude_task_list.dart` alongside the spawn and calls `parser.inherit(...)`
before the first line. A fully completed list is not carried (`claudeTasksToCarry`)
— the CLI's own screen resets such a list when it hides it; `-p` has no screen,
so on disk it stays. Before this, 99 of 336 updates (a task made in an earlier
turn) were dropped.

Cross-agent tables that also name Claude tools (update together):
`_kToolFamilies` (glyph + run summary) and `_gerund` ("Reading…") in
`lib/features/agents/logic/agent_step_label.dart`.

## 4. Content blocks (`claude_content.dart` + parser)

| Block | Where it arrives | Shown as |
|---|---|---|
| `text` (assistant, root) | `assistant` | the answer (deltas while typing, block replaces them) |
| `text` (assistant, sub-agent) | `assistant` + `parent_tool_use_id` | a thinking-kind note under its `Agent` row |
| `thinking` | `assistant` | a thinking row (grid models send none) |
| `tool_use` | `assistant` | a step row via `claudeTool(name)` |
| `tool_result` string / list | `user` | the row's result via `claudeToolResult` |
| `tool_reference` | inside a `tool_result` | the tool's name |
| `image` | inside a `tool_result` | not drawn; counted into context (`claudeMediaTokens`) |
| `text` in the user turn | `user` | "Fed back to the agent" row (hook output) |

What `claudeToolResult` takes off, counted over a month of this machine's
sessions (820 transcripts):

| CLI wrapping | Count | Becomes |
|---|---|---|
| `<tool_use_error>…</tool_use_error>` | 264 | the error text |
| `<system-reminder>` at either **end** | 48 | removed (middle ones are file content — kept) |
| reminder-only result | (Read of empty file) | the reminder's words |
| "The user doesn't want to proceed with this tool use…" | 12 | "You said no to this." / "You said no: <reason>" |
| `[Request interrupted by user]` (+ `for tool use`) in the user turn | 52 | dropped from the import |

## 5. Deliberate differences — don't "fix" them back

- **Read `offset` is 1-based.** Offset 490 → the result opens on line 490. The
  extension shows `offset+1` and is a line out.
- **No withholding of the in-flight paragraph.** The extension renders markdown
  only up to the last `\n\n` while streaming. Grid models are slow; a paragraph
  at a time reads as a stall. `_StreamingReply` throttles to 50ms instead, and
  `markdownFenceIsOpen` handles the half-written code fence.
- **Nothing hidden.** The extension hides `ToolSearch`; Grid names what it
  loaded. The app shows what the CLI did.
- **No thinking deltas.** Grid models emit no thinking blocks; the working
  bubble's "Thinking… Ns" row covers the gap.
- **An unreported step is `unknown`**, not failed (extension: failure).
- **No Monaco.** An `Edit` is a text diff in the payload well, coloured by the
  `diff` grammar; `DiffView` stays for permission cards and the changes bar.
- **Subject keys are measured here**, not the extension's (`message`,
  `channel`, `path` were never sent by a connector on this machine).

## 6. When Claude Code updates — checklist

1. Newest bundle: `ls -d ~/.vscode/extensions/anthropic.claude-code-*`.
2. Its tool list:
   ```sh
   grep -oE 'extends [A-Za-z_$0-9]+\{(static toolName=[^;]+;)?name=("[^"]+"|[A-Za-z_$0-9]+)' webview/index.js | sort -u
   ```
   A `name=Xy` constant resolves with `grep -o 'Xy="[^"]*"' webview/index.js`.
   The registry itself: `grep -o 'function [A-Za-z_$0-9]*(\$,J){let Z=\[new' webview/index.js`.
3. Diff that list against `_kTools` in `claude_tools.dart`.
4. For a new or changed tool, read its class (anchor `name="X"`): `header` →
   `label`/`subject`, `renderInput` → `request`, `renderOutput` → `showsResult`,
   `permissionRequest` → `claude_permission.dart`.
5. Check what it really sends before choosing a key — nothing speculative:
   ```sh
   python3 - <<'PY'
   import json, glob, os, collections
   keys = collections.Counter()
   for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
       for line in open(f, errors='replace'):
           try: e = json.loads(line)
           except Exception: continue
           for b in (e.get('message') or {}).get('content') or []:
               if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'NEW_TOOL':
                   keys.update((b.get('input') or {}).keys())
   print(keys.most_common())
   PY
   ```
6. Add or adjust the entry; add the name to `_kToolFamilies` (and `_gerund` if
   it has a natural "-ing") so its glyph isn't the unclaimed wrench.
7. New content block type? Check the anchor `Unsupported content type` for the
   list, then `claude_content._blockText` and the parser's block switches.
8. New wrapping in results? Look for tags at the edges of `tool_result` text in
   recent sessions; add them to `_readable` with the count.
9. Tests: `test/agent/claude_exec_test.dart` — groups "a tool row says what it
   was about…", "a file change opens as the change…", "what a tool sent back
   reads as what it said…"; `test/agents/agent_step_label_test.dart` for
   families/languages; `test/chat/claude_session_parser_test.dart` for import.
10. Check **which lane** sends what — the VS Code lane and `-p` differ (the plan
    moved from `TodoWrite` to `TaskCreate`/`TaskUpdate` under `-p` only). Every
    session line carries `entrypoint`: `sdk-cli` is this app, `claude-vscode`
    the extension, `cli` the terminal. Count by it before trusting the bundle.
