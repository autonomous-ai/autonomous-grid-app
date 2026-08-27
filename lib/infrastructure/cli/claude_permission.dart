import 'agent_event.dart';
import 'claude_stream_parser.dart';

/// What `--permission-prompt-tool` is given so Claude Code asks *this app*
/// before it runs a tool.
///
/// The flag is real and load-bearing, and it is **not in `claude --help`**
/// (measured against 2.1.x on 2026-08-18). Without it a turn under any
/// permission mode but `bypassPermissions` never asks: the tool is auto-denied
/// with an error result and the model narrates its own failure, which is exactly
/// the quiet no §5 forbids. So a build that stops accepting it must be noticed
/// rather than silently fall back — see [ClaudeExecService]'s start path.
const String kClaudePermissionPromptTool = 'stdio';

/// The answers the app offers for a Claude request, in the ACP shape the chat
/// and [optionIdForChoice] already speak, so one card serves every agent.
///
/// "Allow in this chat" is deliberately absent for a file change: it is the
/// widest of the three, and a standing yes to rewriting a file is not something
/// to hand over in the same click as running one command. Hermes withholds it
/// there too — two agents, one behaviour.
List<HermesPermissionOption> claudePermissionOptions(
  AgentPermissionKind kind,
) => [
  const (optionId: kAllowOnceOption, kind: 'allow_once'),
  if (kind != AgentPermissionKind.edit)
    const (optionId: kAllowForChatOption, kind: 'allow_always'),
  const (optionId: kRefuseOption, kind: 'reject_once'),
];

/// The option ids this app mints for agents whose transport doesn't name its
/// own. Hermes sends real ACP ids; Claude's control channel carries none, so
/// these stand in and must match the kinds [optionIdForChoice] looks for.
const String kAllowOnceOption = 'allow_once';
const String kRefuseOption = 'reject_once';

/// The handshake the CLI's own SDK opens a stream-json session with.
///
/// Sent because that is what was measured working, not because its contents are
/// understood to matter: with the flag and this handshake the CLI asks before it
/// acts, and the reply it sends back is of no use to this app. If a later build
/// starts refusing an empty `hooks`, the symptom is the one worth naming here —
/// tools auto-denied and an agent narrating its own failure.
Map<String, Object?> claudeInitializeRequest() => {
  'type': 'control_request',
  'request_id': 'init',
  'request': {'subtype': 'initialize', 'hooks': <String, Object?>{}},
};

/// The user message envelope for `--input-format stream-json`.
///
/// The prompt travels as JSON on stdin rather than as plain text because the
/// same pipe carries the answers to permission requests — text-mode stdin is
/// one-way, and one-way stdin is the whole reason this app used to run Claude
/// with nobody asked first.
Map<String, Object?> claudeUserMessage(String text) => {
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

/// The answer to a `can_use_tool` request: yes with the tool's input unchanged,
/// or no with a line the model can read.
///
/// Both "allow once" and "allow in this chat" answer the CLI the same way — a
/// plain, one-off yes. The difference is kept **here**, in the app, not handed
/// to Claude as a standing grant: its own way to persist one writes rules into
/// the project's settings file, which outlives the chat that agreed to it and
/// is not what "in this chat" says. See `agentSessionGrantsProvider`.
Map<String, Object?> claudePermissionResponse({
  required String requestId,
  required String? optionId,
  Map<String, Object?> input = const {},
  String? denyMessage,
}) => {
  'type': 'control_response',
  'response': {
    'subtype': 'success',
    'request_id': requestId,
    'response': optionId == null || optionId == kRefuseOption
        ? {
            'behavior': 'deny',
            'message': denyMessage ?? 'The person asked said no.',
          }
        : {'behavior': 'allow', 'updatedInput': input},
  },
};

/// Claude Code's watcher. Useful inside a turn, a lie across one.
const String kClaudeMonitorTool = 'Monitor';

/// Why a `persistent` monitor is refused before the user is ever asked.
///
/// Written to the model, so it says what to do instead rather than only what it
/// cannot have.
const String kClaudePersistentMonitorRefusal =
    'A persistent monitor cannot work here. This turn is a process Grid closes '
    'when the answer lands, so the monitor dies with it and any tool it reaches '
    'for afterwards gets "Stream closed" — the user is told a watch is running '
    'while nothing is watching. For work that must outlive this chat, tell the '
    'user to set it up under Scheduled in Grid. A monitor without `persistent` '
    'is fine: it just has to finish inside this turn.';

/// Why this tool call cannot work in Grid, or null when it can.
///
/// Answered by the transport before the request ever reaches a card: the user
/// saying yes would not make it work, so asking them would be theatre. The one
/// case is a `persistent` monitor, which on 2026-08-20 left a `claude -p` alive
/// two hours past its own turn, aborting every permission it asked for.
String? claudeToolRefusal(String tool, Map<Object?, Object?> input) =>
    tool == kClaudeMonitorTool && input['persistent'] == true
    ? kClaudePersistentMonitorRefusal
    : null;

/// The tool a `can_use_tool` request is about, or '' when the line isn't one.
String claudePermissionTool(Map<String, dynamic> event) {
  final request = event['request'];
  if (request is! Map) return '';
  final tool = request['tool_name'];
  return tool is String ? tool : '';
}

/// The input a `can_use_tool` request carries, keyed by name.
///
/// A yes has to echo this back unchanged, and [claudeToolRefusal] reads it to
/// decide whether a yes would mean anything.
Map<String, Object?> claudePermissionInput(Map<String, dynamic> event) {
  final request = event['request'];
  final input = request is Map ? request['input'] : null;
  if (input is! Map) return const {};
  return {for (final entry in input.entries) '${entry.key}': entry.value};
}

/// The request Claude Code is blocked on, or null when the line isn't one.
///
/// Shape, measured against the real binary: a `control_request` carrying
/// `request_id` and a `request` of subtype `can_use_tool`, with the tool's name
/// and the exact input it would run. The CLI **waits** — nothing happens on that
/// tool until a `control_response` with the same `request_id` goes back.
///
/// [readBefore] reads a file the agent wants to change, so the card can show a
/// real before/after instead of a bare path. Injected rather than called here so
/// this stays pure and testable; null simply leaves the diff one-sided.
AgentPermission? parseClaudePermission(
  Map<String, dynamic> event, {
  String? Function(String path)? readBefore,
}) {
  if (event['type'] != 'control_request') return null;
  final request = event['request'];
  if (request is! Map) return null;
  if (request['subtype'] != 'can_use_tool') return null;
  final id = event['request_id'];
  if (id is! String || id.isEmpty) return null;
  final tool = request['tool_name'];
  if (tool is! String || tool.isEmpty) return null;

  final raw = request['input'];
  final input = raw is Map ? raw : const {};
  final kind = claudeToolPermissionKind(tool);
  return switch (kind) {
    AgentPermissionKind.command => _command(id, tool, input),
    AgentPermissionKind.edit => _edit(id, tool, input, readBefore),
    AgentPermissionKind.other => _other(id, tool, input),
  };
}

/// Which of the three cards a Claude tool call is drawn as. Anything the app has
/// no drawing for is still shown — as the tool's own name over its raw input —
/// because a request the user can read is one they can judge, and refusing it
/// unasked would be a no from a chat that promised to ask.
AgentPermissionKind claudeToolPermissionKind(String tool) {
  if (tool == kClaudeShellTool) return AgentPermissionKind.command;
  if (kClaudeFileWriteTools.contains(tool)) return AgentPermissionKind.edit;
  return AgentPermissionKind.other;
}

/// Claude Code's shell tool — the one call that runs anything on this computer.
const String kClaudeShellTool = 'Bash';

AgentPermission _command(String id, String tool, Map<Object?, Object?> input) {
  final command = _text(input['command']) ?? '';
  final why = _text(input['description']);
  return AgentPermission(
    id: id,
    kind: AgentPermissionKind.command,
    summary: why ?? command,
    command: command,
    options: claudePermissionOptions(AgentPermissionKind.command),
  );
}

AgentPermission _edit(
  String id,
  String tool,
  Map<Object?, Object?> input,
  String? Function(String path)? readBefore,
) {
  final path = _text(input['file_path']) ?? _text(input['notebook_path']) ?? '';
  final before = path.isEmpty ? null : readBefore?.call(path);
  return AgentPermission(
    id: id,
    kind: AgentPermissionKind.edit,
    summary: path,
    path: path,
    oldText: before,
    newText: claudeEditResult(input, before) ?? before ?? '',
    options: claudePermissionOptions(AgentPermissionKind.edit),
  );
}

/// What the file would contain if the change were allowed, or null when the
/// input doesn't say.
///
/// `Write` carries the whole new file. `Edit` carries only the fragment it swaps,
/// so the after-text is the before-text with that swap applied — which is why a
/// file we couldn't read gives no honest after either, and the card falls back
/// to showing the path alone.
String? claudeEditResult(Map<Object?, Object?> input, String? before) {
  final whole = _text(input['content']) ?? _text(input['new_source']);
  if (whole != null) return whole;
  final from = _text(input['old_string']);
  final to = _text(input['new_string']);
  if (from == null || to == null || before == null) return null;
  return input['replace_all'] == true
      ? before.replaceAll(from, to)
      : before.replaceFirst(from, to);
}

AgentPermission _other(String id, String tool, Map<Object?, Object?> input) =>
    AgentPermission(
      id: id,
      kind: AgentPermissionKind.other,
      summary: tool,
      command: _describeInput(input),
      options: claudePermissionOptions(AgentPermissionKind.other),
    );

/// The tool's input as one readable line, for a call the app can't draw — the
/// user is being asked about it, so they get to see all of it.
String _describeInput(Map<Object?, Object?> input) =>
    input.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n');

/// What "Allow in this chat" remembers, so the same request doesn't come back a
/// second time.
///
/// Narrow on purpose: the exact command, or the exact file. A yes to
/// `rm -rf build` is not a yes to `rm -rf /`, and the app can only honour that
/// difference if what it remembers is the command itself.
String claudePermissionGrantKey(AgentPermission request) =>
    switch (request.kind) {
      AgentPermissionKind.command => 'command:${request.command}',
      AgentPermissionKind.edit => 'edit:${request.path}',
      AgentPermissionKind.other => 'tool:${request.summary}',
    };

String? _text(Object? raw) => raw is String && raw.isNotEmpty ? raw : null;
