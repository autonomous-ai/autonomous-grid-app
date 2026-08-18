import 'agent_event.dart';
import 'model_control_tokens.dart';
import 'codex_agent_service.dart';

/// Turns the `codex app-server` protocol into the shapes the chat already
/// renders — the same [CodexEvent]s the old `codex exec --json` transport
/// produced, so nothing downstream had to learn a second vocabulary.
///
/// The vocabulary here is JSON-RPC, not JSONL: the server sends *notifications*
/// (`item/started`, `item/completed`, `item/agentMessage/delta`,
/// `turn/completed`) and, when it needs an answer, *requests* — which is the
/// whole reason this transport exists. See [parseCodexApproval].
///
/// Verified against the pinned build (`rust-v0.144.6`) by driving the real
/// binary over stdio on 2026-08-18, not read off the schema alone: a turn there
/// produced `thread/started`, `turn/started`, `item/started`, `item/completed`,
/// `item/agentMessage/delta`, `turn/completed` in that order, and a command that
/// had to escalate produced `item/commandExecution/requestApproval`.
///
/// [messages] accumulates the answer by item id, exactly as the old parser did:
/// the text arrives twice over — as deltas while the model types, then whole
/// when the item completes — and the whole one replaces the deltas rather than
/// being appended to them.
CodexEvent? parseCodexAppServerEvent({
  required String method,
  required Map<String, dynamic> params,
  required Map<String, String> messages,
}) {
  switch (method) {
    case 'thread/started':
      final thread = params['thread'];
      final id = thread is Map ? thread['id'] : null;
      return id is String && id.isNotEmpty ? CodexThreadStarted(id) : null;
    case 'item/agentMessage/delta':
      final delta = params['delta'];
      if (delta is! String || delta.isEmpty) return null;
      final id = '${params['itemId'] ?? ''}';
      messages[id] = (messages[id] ?? '') + delta;
      return CodexMessageEvent(codexJoinedAnswer(messages));
    case 'item/started':
    case 'item/completed':
      final item = params['item'];
      return item is Map
          ? parseCodexAppServerItem(item.cast<String, dynamic>(), messages)
          : null;
    case 'turn/plan/updated':
      final plan = _plan(params['plan']);
      return plan.isEmpty ? null : CodexPlanEvent(plan);
    case 'turn/completed':
      final turn = params['turn'];
      final failure = turn is Map ? _turnFailure(turn) : null;
      return failure == null
          ? const CodexTurnCompleted()
          : CodexTurnFailed(failure);
    case 'error':
      // A retryable error is Codex telling us it is reconnecting, not that the
      // turn is over — saying "the turn failed" here would put an error over a
      // turn that goes on to answer.
      if (params['willRetry'] == true) return null;
      return CodexTurnFailed(_errorMessage(params['error']));
    default:
      // Token counts, rate limits, MCP startup, a notification a later build
      // adds: nothing to show. Tolerant on purpose — this protocol is marked
      // experimental and will grow.
      return null;
  }
}

/// The answer so far: every message item's text, in the order they arrived.
String codexJoinedAnswer(Map<String, String> messages) => stripControlTokens(
  messages.values.where((m) => m.trim().isNotEmpty).join('\n\n'),
);

/// One `ThreadItem`, whatever stage of its life it is at.
CodexEvent? parseCodexAppServerItem(
  Map<String, dynamic> item,
  Map<String, String> messages,
) {
  final id = '${item['id'] ?? ''}';
  switch (item['type']) {
    case 'agentMessage':
      final text = '${item['text'] ?? ''}';
      if (text.isEmpty) return null;
      // The whole block, replacing whatever its deltas had built.
      messages[id] = text;
      return CodexMessageEvent(codexJoinedAnswer(messages));
    case 'commandExecution':
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.command,
          label: '${item['command'] ?? 'command'}',
          status: codexItemStatus(item['status']),
          tool: 'Shell',
          request: clipToolPayload('${item['command'] ?? ''}'),
          result: clipToolPayload('${item['aggregatedOutput'] ?? ''}'),
        ),
      );
    case 'webSearch':
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.web,
          label: '${item['query'] ?? 'Web search'}',
          status: codexItemStatus(item['status']),
          tool: 'Web search',
          request: clipToolPayload('${item['query'] ?? ''}'),
        ),
      );
    case 'mcpToolCall':
      final tool = item['tool'] ?? item['server'] ?? 'tool';
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.tool,
          label: '$tool',
          status: codexItemStatus(item['status']),
          tool: '$tool',
          request: clipToolPayload(codexPayloadText(item['arguments'])),
          result: clipToolPayload(codexPayloadText(item['result'])),
        ),
      );
    case 'fileChange':
      return _fileChange(item);
    // `reasoning` carries the model's own summary and arrived empty on every
    // captured run (the grid's `auto` model emits none); `userMessage` is the
    // prompt this app just sent. Neither is worth a row.
    default:
      return null;
  }
}

/// A landed patch, as the chat's open/undo bar's raw material. Only once it has
/// actually applied: an in-flight patch has written nothing to open, and a
/// declined one wrote nothing at all.
///
/// TODO(BE): this transport carries a **unified `diff` per file**, which the old
/// one dropped — so an *edited* file could now be shown with an honest
/// before/after and undone, not just a freshly created one (see
/// [codexAddedPaths]). The diff is read here and thrown away; wiring it through
/// [CodexFileChange] is a change to the changes bar, kept out of the transport
/// swap deliberately.
CodexEvent? _fileChange(Map<String, dynamic> item) {
  if (codexItemStatus(item['status']) != AgentActivityStatus.done) return null;
  final raw = item['changes'];
  if (raw is! List) return null;
  final changes = <CodexFileChange>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final path = '${entry['path'] ?? ''}'.trim();
    if (path.isEmpty) continue;
    changes.add((path: path, kind: codexChangeKind(entry['kind'])));
  }
  return changes.isEmpty ? null : CodexFileChangeEvent(changes);
}

/// `add` / `update` / `delete`; anything else reads as an update — the
/// conservative choice, since only an add is ever recorded for undo, so
/// mislabelling one drops it rather than faking an undo.
CodexFileChangeKind codexChangeKind(Object? raw) => switch (raw) {
  'add' => CodexFileChangeKind.add,
  'delete' => CodexFileChangeKind.delete,
  _ => CodexFileChangeKind.update,
};

/// This protocol spells its lifecycle in camelCase (`inProgress`, `completed`,
/// `failed`, `declined`) where the old one used snake_case — a rename that would
/// otherwise show every finished command as still running.
AgentActivityStatus codexItemStatus(Object? raw) => switch (raw) {
  'completed' => AgentActivityStatus.done,
  'failed' || 'declined' => AgentActivityStatus.failed,
  _ => AgentActivityStatus.running,
};

List<AgentPlanEntry> _plan(Object? raw) {
  if (raw is! List) return const [];
  final steps = <AgentPlanEntry>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final text = '${entry['step'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    steps.add(
      AgentPlanEntry(content: text, status: _planStatus(entry['status'])),
    );
  }
  return List.unmodifiable(steps);
}

AgentPlanStatus _planStatus(Object? raw) => switch (raw) {
  'completed' => AgentPlanStatus.done,
  'inProgress' => AgentPlanStatus.active,
  _ => AgentPlanStatus.pending,
};

/// Why the turn ended badly, or null when it simply ended.
String? _turnFailure(Map<Object?, Object?> turn) {
  if (turn['status'] != 'failed') return null;
  return _errorMessage(turn['error']);
}

String _errorMessage(Object? raw) {
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  if (raw is Map) {
    final message = raw['message'];
    if (message is String && message.trim().isNotEmpty) return message.trim();
  }
  return 'Codex ended the turn without saying why.';
}

/// A tool payload as text: a string as it stands, anything structured
/// pretty-printed, null for absent.
String? codexPayloadText(Object? raw) => switch (raw) {
  null => null,
  final String text => text,
  _ => '$raw',
};
