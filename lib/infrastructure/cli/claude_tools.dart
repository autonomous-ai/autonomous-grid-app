/// Everything the app knows about Claude Code's tools — one entry per tool,
/// looked up by name.
///
/// **Laid out the way Claude Code's own VS Code panel lays it out.** Its
/// webview keeps one renderer class per tool in a single list, finds a call's
/// renderer by name, and falls back to a browser renderer, then a connector
/// renderer for `mcp__…`, then a generic one. Mirroring that shape is what
/// makes a new Claude Code release cheap to follow: a new tool, or a tool
/// that starts taking a different argument, is one entry here — and the
/// extension's class of the same name is the reference for what it sends.
/// The method-by-method map, the strings that find each piece in the minified
/// bundle, and the checklist for a release are in `docs/claude-rendering.md`.
///
/// Text only. An entry decides *what* a step row says and what its fold
/// holds; the feed draws every tool's row the same way, so nothing here knows
/// about widgets. The stateful half of reading the stream — which call a
/// result settles, what a sub-agent owns — stays in `ClaudeStreamParser`.
library;

import 'dart:convert';

import '../../core/edit_diff.dart';
import '../../core/folder_name.dart';
import 'agent_event.dart';
import 'tool_subject.dart';

/// How the feed shows a call to one of Claude Code's tools.
///
/// The twin of one renderer class in the VS Code extension: [label] is its
/// `header`, [request] its `renderInput`, and [showsResult] whether its
/// `renderOutput` draws anything. Override only what a tool does differently
/// — most differ in [subject] alone.
abstract class ClaudeTool {
  const ClaudeTool(this.name, {this.kind = AgentActivityKind.tool});

  /// The tool's name on the wire: `Bash`, `Read`, `mcp__gitnexus__impact`.
  final String name;

  /// What kind of step a call is — a shell command, a look-up on the web, or
  /// any other tool — which picks the glyph its row starts with.
  final AgentActivityKind kind;

  /// The one line the feed shows for a call: the thing it is *about*, not the
  /// tool's name, wherever the input carries it. A row reading "Bash" eight
  /// times says nothing; the commands do.
  String label(Map<String, dynamic> input) {
    final about = subject(input).trim();
    return about.isEmpty ? name : '$name · $about';
  }

  /// What a call is about — the half of [label] after the name. The file it
  /// touched unless a tool says otherwise: every file tool names one, and so
  /// does a tool this app has never met that takes a `file_path`.
  String subject(Map<String, dynamic> input) =>
      _fileName(input['file_path'] ?? input['notebook_path']);

  /// What the call asked for, as the fold under its row shows it, or null to
  /// show nothing. Uncapped — the parser clips it.
  ///
  /// Verified against the real binary (Claude Code 2.1): every `tool_use`
  /// block carries its whole `input`, so by default the fold shows the call
  /// itself, pretty-printed, rather than the row's one-line summary of it a
  /// second time.
  String? request(Map<String, dynamic> input) {
    if (input.isEmpty) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(input);
    } on JsonUnsupportedObjectError {
      // A shape `dart:convert` can't walk. The row and its title still stand;
      // only the fold goes, which is better than dropping the step.
      return null;
    }
  }

  /// Whether the fold shows what the tool answered. False only where the
  /// answer is the CLI coaching the model — see [_PlanModeTool].
  bool get showsResult => true;

  /// Whether a call changes a file on disk: only these are recorded for undo
  /// and offered to open once the answer lands, and only these ask permission
  /// as an edit rather than as a command.
  bool get editsFiles => false;
}

/// The entry for the tool called [name]: its own when it has one, else the
/// browser, connector or generic entry its name puts it under — the order the
/// extension falls back in. Never null: a tool this app has not met still
/// ran, and still gets a row.
ClaudeTool claudeTool(String name) {
  if (_kByName[name] case final tool?) return tool;
  if (_isBrowserTool(name)) return _BrowserTool(name);
  if (name.startsWith('mcp__')) return _ConnectorTool(name);
  return _GenericTool(name);
}

/// Every tool with an entry of its own — each a name Claude Code actually
/// sends. What isn't listed falls through to [claudeTool]'s fallbacks.
///
/// The plan tools are missing on purpose — `TodoWrite`, and the task list
/// Claude Code 2.1 keeps under `-p` (`TaskCreate`, `TaskUpdate`, `TaskList`,
/// `TaskGet`) — and so is `AskUserQuestion`: none is a step the user watches
/// happen. The parser turns the first into the plan and the last into a card
/// before any of them reaches this list.
const List<ClaudeTool> _kTools = [
  _BashTool(),
  _GenericTool('BashOutput', kind: AgentActivityKind.command),
  _GenericTool('KillShell', kind: AgentActivityKind.command),
  _ReadTool(),
  _EditTool(),
  _WriteTool(),
  _FileTool('NotebookEdit'),
  _KeyedTool('Glob', 'pattern'),
  _KeyedTool('Grep', 'pattern'),
  _KeyedTool('WebSearch', 'query', kind: AgentActivityKind.web),
  _KeyedTool('WebFetch', 'url', kind: AgentActivityKind.web),
  // `Agent` is this tool's name in Claude Code 2.x and `Task` was its name
  // before; both are kept because the app pins no version of the CLI. The
  // description is the job it was given — titling only `Task` once left every
  // `Agent` row (31 of them here, and no `Task`) reading "Agent" alone.
  _KeyedTool('Agent', 'description'),
  _KeyedTool('Task', 'description'),
  // Which skill, not that a skill ran.
  _KeyedTool('Skill', 'skill'),
  _KeyedTool('CronCreate', 'cron'),
  _ScheduleWakeupTool(),
  _ToolSearchTool(),
  _PlanModeTool('EnterPlanMode', 'Planning before changing anything'),
  _ExitPlanModeTool(),
];

final Map<String, ClaudeTool> _kByName = {
  for (final tool in _kTools) tool.name: tool,
};

/// A tool with nothing of its own to add: titled by the file it touched, if
/// any, with its arguments behind the fold. Also the entry for a tool this
/// app has never met.
class _GenericTool extends ClaudeTool {
  const _GenericTool(super.name, {super.kind});
}

/// A tool whose subject is one of its arguments, as given.
class _KeyedTool extends ClaudeTool {
  const _KeyedTool(super.name, this.key, {super.kind});

  /// The argument that says what a call is about.
  final String key;

  @override
  String subject(Map<String, dynamic> input) => '${input[key] ?? ''}';
}

/// `Bash`: the command is the row's subject and the whole of its request.
class _BashTool extends _KeyedTool {
  const _BashTool() : super('Bash', 'command', kind: AgentActivityKind.command);

  /// The bare command line rather than `{"command": …}`: a shell command in
  /// JSON quotes and `\n` escapes is harder to read than the thing itself, and
  /// it is the payload a user is likeliest to copy. Only for `Bash`, by name —
  /// unwrapping any `command` key turned a browser server's
  /// `{command: 'click', selector: '#buy'}` into the word `click`.
  @override
  String? request(Map<String, dynamic> input) =>
      _text(input['command']) ?? super.request(input);
}

/// `Read`: the file, and which of its lines when it did not read them all.
///
/// 1,739 of 5,632 reads in a month of this machine's sessions took an
/// `offset` or a `limit`, and a row reading "Read · conventions.md" for lines
/// 490–569 says the whole file was read. `offset` is the first line **as the
/// result numbers it** — measured: an offset of 490 comes back opening on
/// line 490. (The extension adds one to it, and is a line out.)
class _ReadTool extends ClaudeTool {
  const _ReadTool() : super('Read');

  @override
  String subject(Map<String, dynamic> input) {
    final file = super.subject(input);
    final range = _lineRange(input['offset'], input['limit']);
    return file.isEmpty || range.isEmpty ? file : '$file ($range)';
  }
}

/// A tool that changes a file — see [ClaudeTool.editsFiles].
class _FileTool extends ClaudeTool {
  const _FileTool(super.name);

  @override
  bool get editsFiles => true;
}

/// `Edit`: the request is the change, as a unified diff of the lines it swaps
/// headed by the file (`--- path` / `+++ path`) — which is also what tells the
/// feed to colour it as one. The lines the two snippets share at either end
/// are cut to the few that place the change, the way the permission card
/// shows an edit ([buildEditDiff]). As JSON it was one line of `\n` escapes in
/// a well that scrolls sideways, on the third commonest call there is (3,960
/// in a month here). An edit that changes nothing keeps its arguments.
class _EditTool extends _FileTool {
  const _EditTool() : super('Edit');

  @override
  String? request(Map<String, dynamic> input) =>
      _editDiff(input) ?? super.request(input);
}

/// `Write`: the request is the file it wrote, which the fold colours as that
/// file's language — not its JSON, where the whole file was one escaped line.
class _WriteTool extends _FileTool {
  const _WriteTool() : super('Write');

  @override
  String? request(Map<String, dynamic> input) =>
      _text(input['content']) ?? super.request(input);
}

/// `ScheduleWakeup`: when the next tick is and why — or that the loop is
/// being ended.
class _ScheduleWakeupTool extends ClaudeTool {
  const _ScheduleWakeupTool() : super('ScheduleWakeup');

  @override
  String subject(Map<String, dynamic> input) => input['stop'] == true
      ? 'stop'
      : 'in ${input['delaySeconds']}s · ${input['reason'] ?? ''}';
}

/// `ToolSearch`: what it went to fetch. Claude Code keeps most tools out of
/// the prompt until one is needed, and this call loads it — 59 of them in a
/// month here, each a `select:` of names. A connector's is said the way the
/// rest of the feed says it ("gitnexus impact", not its wire identifier); a
/// keyword search is shown as typed. Its answer names the tools it loaded
/// (see `claudeToolResult`).
class _ToolSearchTool extends ClaudeTool {
  const _ToolSearchTool() : super('ToolSearch');

  @override
  String subject(Map<String, dynamic> input) {
    final query = '${input['query'] ?? ''}'.trim();
    const select = 'select:';
    if (!query.startsWith(select)) return query;
    return [
      for (final name in query.substring(select.length).split(','))
        if (name.trim().isNotEmpty) _spokenToolName(name.trim()),
    ].join(', ');
  }
}

/// A plan-mode tool. It acts on nothing, so its row says what happened in the
/// user's words, and its answer stays behind: `EnterPlanMode` answers with a
/// page of instructions to the assistant ("DO NOT write or edit any files
/// yet") and `ExitPlanMode` with the sentence that releases it. Shown, both
/// read as the app telling the user what to do.
class _PlanModeTool extends ClaudeTool {
  const _PlanModeTool(super.name, this.phrase);

  /// What the step did, said the way the user would say it.
  final String phrase;

  @override
  String label(Map<String, dynamic> input) => phrase;

  @override
  bool get showsResult => false;
}

/// `ExitPlanMode`: its request is the plan, as the markdown the model wrote —
/// the one payload a user reads rather than inspects, and one long line of
/// `\n` as JSON.
class _ExitPlanModeTool extends _PlanModeTool {
  const _ExitPlanModeTool() : super('ExitPlanMode', 'Finished the plan');

  @override
  String? request(Map<String, dynamic> input) =>
      _text(input['plan'])?.trim() ?? super.request(input);
}

/// The MCP servers a browser lane hands the turn: the Claude in Chrome
/// extension, and the app's own browser over the DevTools protocol.
const _kBrowserToolPrefixes = [
  'mcp__claude-in-chrome__',
  'mcp__chrome-devtools__',
];

/// Whether [name] is a call into a browser rather than into this computer.
bool _isBrowserTool(String name) => _kBrowserToolPrefixes.any(name.startsWith);

/// A browser step, said the way the user would say it: "Browser · navigate
/// page · example.com".
///
/// The feed is the only place a user sees that an agent is driving their
/// browser — no button turned it on and none shows it running — so a row
/// reading `mcp__claude-in-chrome__navigate_page` is a step nobody can act on.
/// The server is dropped: which of the two lanes drove it is a routing detail
/// the log already carries.
class _BrowserTool extends ClaudeTool {
  const _BrowserTool(super.name) : super(kind: AgentActivityKind.web);

  @override
  String label(Map<String, dynamic> input) {
    final action = name.split('__').last.replaceAll('_', ' ').trim();
    final about = toolSubject(input, _kBrowserSubjects);
    return [
      'Browser',
      if (action.isNotEmpty) action,
      if (about.isNotEmpty) about,
    ].join(' · ');
  }
}

/// A connector's tool, as `server · tool · subject` rather than the wire
/// identifier. MCP names arrive as `mcp__<server>__<tool>` —
/// `mcp__plugin_playwright_playwright__browser_navigate` is one real row — and
/// a line of that spends its whole width on plumbing nobody chose by name.
class _ConnectorTool extends ClaudeTool {
  const _ConnectorTool(super.name);

  @override
  String label(Map<String, dynamic> input) {
    final parts = name.split('__').where((p) => p.isNotEmpty).toList();
    return connectorLabel(
      server: parts.length > 1 ? parts[1] : '',
      tool: parts.length > 2 ? parts.last : '',
      input: input,
    );
  }
}

/// The arguments that say what a browser call is about: its actions take a
/// page, a query, text to type, or an element.
const _kBrowserSubjects = ['url', 'query', 'text', 'value', 'selector', 'uid'];

/// A tool's name as the feed says it — a connector's as "server tool".
String _spokenToolName(String name) => name.startsWith('mcp__')
    ? _ConnectorTool(name).label(const {}).replaceAll(' · ', ' ')
    : name;

/// "lines 490–569", "from line 12", "lines 1–200" — or '' for a whole file.
String _lineRange(Object? offset, Object? limit) {
  final from = offset is num && offset >= 1 ? offset.toInt() : null;
  final count = limit is num && limit >= 1 ? limit.toInt() : null;
  return switch ((from, count)) {
    (final from?, final count?) => 'lines $from–${from + count - 1}',
    (final from?, null) => 'from line $from',
    (null, final count?) => 'lines 1–$count',
    (null, null) => '',
  };
}

/// The diff an `Edit` makes, or null when it makes none.
String? _editDiff(Map<String, dynamic> input) {
  final before = input['old_string'];
  final after = input['new_string'];
  if (before is! String || after is! String) return null;
  final lines = buildEditDiff(before, after);
  if (lines.isEmpty) return null;
  final path = '${input['file_path'] ?? ''}'.trim();
  return [
    '--- $path',
    '+++ $path',
    for (final line in lines) '${_mark(line.kind)}${line.text}',
  ].join('\n');
}

String _mark(DiffLineKind kind) => switch (kind) {
  DiffLineKind.context => ' ',
  DiffLineKind.removed => '-',
  DiffLineKind.added => '+',
};

/// The last segment of a path — the feed has one line, and an absolute path
/// spends all of it on folders the user already knows they're in.
String _fileName(Object? path) => folderName('${path ?? ''}'.trim());

String? _text(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;
