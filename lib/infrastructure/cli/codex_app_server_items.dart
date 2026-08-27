import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_parser.dart' show codexJoinedAnswer;
import 'codex_app_server_rows.dart';

/// One `ThreadItem`, whatever stage of its life it is at.
///
/// [parent] is the row a helper's items nest under — the call that spawned it —
/// and [helper] says the item is a helper's at all, which matters for the two
/// items that read differently depending on whose they are: a message (the
/// answer, or a note) and a spawn (whose helpers are recorded in [agents] only
/// when this thread did the spawning).
CodexEvent? parseCodexAppServerItem(
  Map<String, dynamic> item,
  Map<String, String> messages, {
  Map<String, String> agents = const {},
  String? parent,
  bool helper = false,
}) {
  final id = '${item['id'] ?? ''}';
  switch (item['type']) {
    case 'agentMessage':
      final text = '${item['text'] ?? ''}';
      if (text.trim().isEmpty) return null;
      // A helper's prose is written to the agent that asked for it, not to
      // the user; folded into the reply it switched voice mid-answer. It is
      // still the only account of what the helper did, so it is kept as a
      // note under the row that started it.
      if (helper) return codexNoteRow(id, text, parent);
      // The whole block, replacing whatever its deltas had built.
      messages[id] = text;
      return CodexMessageEvent(codexJoinedAnswer(messages));
    case 'reasoning':
      // The model's own summary of its thinking, when the model sends one:
      // `summary` on OpenAI's models, `content` on a grid model that streams
      // its reasoning whole (measured with DeepSeek-V4-Flash, 2026-08-27).
      final thought = codexTextLines(item['summary']).isNotEmpty
          ? codexTextLines(item['summary'])
          : codexTextLines(item['content']);
      if (thought.isEmpty) return null;
      return codexNoteRow(id, thought, parent);
    case 'plan':
      // The plan Codex proposes before acting — a page of prose, not the
      // ticked to-do list `turn/plan/updated` carries — so it goes behind the
      // fold like a thought rather than being clipped into a row.
      final text = '${item['text'] ?? ''}'.trim();
      return text.isEmpty ? null : codexNoteRow(id, text, parent);
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
          parent: parent,
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
          parent: parent,
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
          parent: parent,
        ),
      );
    case 'dynamicToolCall':
      final tool = '${item['tool'] ?? 'tool'}';
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.tool,
          label: tool,
          status: codexItemStatus(item['status']),
          tool: tool,
          request: clipToolPayload(codexPayloadText(item['arguments'])),
          result: clipToolPayload(codexTextLines(item['contentItems'])),
          parent: parent,
        ),
      );
    case 'collabAgentToolCall':
      return codexCollabRow(
        id,
        item,
        agents: agents,
        parent: parent,
        helper: helper,
      );
    case 'imageView':
      return codexStepRow(
        id,
        'Looked at ${item['path'] ?? 'an image'}',
        tool: 'Image',
        parent: parent,
      );
    case 'imageGeneration':
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.tool,
          label: 'Generated an image',
          status: codexItemStatus(item['status']),
          tool: 'Image',
          request: clipToolPayload(codexPayloadText(item['revisedPrompt'])),
          result: clipToolPayload(
            codexPayloadText(item['savedPath'] ?? item['result']),
          ),
          parent: parent,
        ),
      );
    case 'sleep':
      final ms = item['durationMs'];
      final seconds = ms is num ? (ms / 1000).round() : null;
      return codexStepRow(
        id,
        seconds == null ? 'Waited a moment' : 'Waited ${seconds}s',
        tool: 'Wait',
        parent: parent,
      );
    case 'enteredReviewMode':
      return codexStepRow(
        id,
        'Started a review',
        tool: 'Review',
        request: codexPayloadText(item['review']),
        parent: parent,
      );
    case 'exitedReviewMode':
      return codexStepRow(
        id,
        'Finished the review',
        tool: 'Review',
        result: codexPayloadText(item['review']),
        parent: parent,
      );
    case 'contextCompaction':
      return codexStepRow(
        id,
        'Made room in the conversation',
        tool: 'Compact',
        parent: parent,
      );
    case 'fileChange':
      return _fileChange(item);
    // `userMessage` is the prompt this app just sent; `hookPrompt` is a hook's
    // and `subAgentActivity` is the bookkeeping behind the collab rows above.
    // None is worth a row.
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

/// A tool payload as text: a string as it stands, anything structured
/// pretty-printed, null for absent.
String? codexPayloadText(Object? raw) => switch (raw) {
  null => null,
  final String text => text,
  _ => '$raw',
};
