import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_items.dart';
import 'model_control_tokens.dart';

export 'codex_app_server_items.dart';

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
/// **Every notification names its thread, and not all of them are ours.**
/// Codex 0.144.6 ships `multi_agent` on, and a helper the model spawns runs as
/// a thread of its own on the *same* stream (measured 2026-08-27): its
/// `agentMessage` "ok" arrived 2s before the parent's answer and its
/// `turn/completed` 2s before the parent's. Read without [thread], the first
/// was folded into the reply and the second ended the turn — the server was
/// killed while the parent was still typing. So [thread] is the conversation
/// this turn belongs to, and anything from another thread is a helper's: its
/// steps are shown under the call that started it ([agents]), its words are a
/// note rather than the answer, and its turn ending is not ours ending.
///
/// [messages] accumulates the answer by item id, exactly as the old parser did:
/// the text arrives twice over — as deltas while the model types, then whole
/// when the item completes — and the whole one replaces the deltas rather than
/// being appended to them.
///
/// [agents] maps a helper thread's id to the `collabAgentToolCall` item that
/// spawned it; filled in here as spawns complete, so it is the caller's map to
/// keep across notifications, like [messages].
CodexEvent? parseCodexAppServerEvent({
  required String method,
  required Map<String, dynamic> params,
  required Map<String, String> messages,
  String? thread,
  Map<String, String> agents = const {},
}) {
  final owner = _threadOf(params);
  final helper = thread != null && owner != null && owner != thread;
  switch (method) {
    case 'thread/started':
      final started = params['thread'];
      final id = started is Map ? started['id'] : null;
      return id is String && id.isNotEmpty ? CodexThreadStarted(id) : null;
    case 'item/agentMessage/delta':
      // A helper's typing is not the answer; its whole message is read as a
      // note when the item completes.
      if (helper) return null;
      final delta = params['delta'];
      if (delta is! String || delta.isEmpty) return null;
      final id = '${params['itemId'] ?? ''}';
      messages[id] = (messages[id] ?? '') + delta;
      return CodexMessageEvent(codexJoinedAnswer(messages));
    case 'item/started':
    case 'item/completed':
      final item = params['item'];
      if (item is! Map) return null;
      return parseCodexAppServerItem(
        item.cast<String, dynamic>(),
        messages,
        agents: agents,
        parent: helper ? agents[owner] : null,
        helper: helper,
      );
    case 'turn/plan/updated':
      if (helper) return null;
      final plan = _plan(params['plan']);
      return plan.isEmpty ? null : CodexPlanEvent(plan);
    case 'turn/completed':
      // A helper finishing its turn is a step done, not this turn over: the
      // parent is still working and has yet to answer.
      if (helper) return null;
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

String? _threadOf(Map<String, dynamic> params) {
  final id = params['threadId'];
  return id is String && id.isNotEmpty ? id : null;
}

/// The answer so far: every message item's text, in the order they arrived.
String codexJoinedAnswer(Map<String, String> messages) => stripControlTokens(
  messages.values.where((m) => m.trim().isNotEmpty).join('\n\n'),
);

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
