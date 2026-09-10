import 'dart:convert';

import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_parser.dart' show codexJoinedAnswer;
import 'codex_app_server_rows.dart';
import 'codex_command_actions.dart';
import 'codex_file_changes.dart';

/// What one `ThreadItem` stands for, whatever stage of its life it is at — a
/// list, because a patch is a row per file *and* the record the open/undo bar
/// keeps.
///
/// The Grid twin of the switch Codex's own VS Code panel runs over a thread's
/// items (see `docs/codex-rendering.md`): one case per item type, with the
/// command and patch vocabulary pulled out into [codexCommandActivity] and
/// [codexFileChangeEvents] the way the panel keeps `cy()` and `ly()` apart.
///
/// [parent] is the row a helper's items nest under — the call that spawned it —
/// and [helper] says the item is a helper's at all, which matters for the two
/// items that read differently depending on whose they are: a message (the
/// answer, or a note) and a spawn (whose helpers are recorded in [agents] only
/// when this thread did the spawning). [completed] is whether this is the
/// item's `item/completed` — the only way to settle an item that carries no
/// status of its own.
List<CodexEvent> parseCodexAppServerItem(
  Map<String, dynamic> item,
  Map<String, String> messages, {
  Map<String, String> agents = const {},
  String? parent,
  bool helper = false,
  bool completed = false,
}) {
  final id = '${item['id'] ?? ''}';
  switch (item['type']) {
    case 'agentMessage':
      final text = '${item['text'] ?? ''}';
      if (text.trim().isEmpty) return const [];
      // A helper's prose is written to the agent that asked for it, not to
      // the user; folded into the reply it switched voice mid-answer. It is
      // still the only account of what the helper did, so it is kept as a
      // note under the row that started it.
      if (helper) return [codexNoteRow(id, text, parent)];
      // The whole block, replacing whatever its deltas had built.
      messages[id] = text;
      return [CodexMessageEvent(codexJoinedAnswer(messages))];
    case 'reasoning':
      // The model's own summary of its thinking, when the model sends one:
      // `summary` on OpenAI's models, `content` on a grid model that streams
      // its reasoning whole (measured with DeepSeek-V4-Flash, 2026-08-27).
      final thought = codexTextLines(item['summary']).isNotEmpty
          ? codexTextLines(item['summary'])
          : codexTextLines(item['content']);
      if (thought.isEmpty) return const [];
      return [codexNoteRow(id, thought, parent)];
    case 'plan':
      // The plan Codex proposes before acting — a page of prose, not the
      // ticked to-do list `turn/plan/updated` carries — so it goes behind the
      // fold like a thought rather than being clipped into a row.
      final text = '${item['text'] ?? ''}'.trim();
      return text.isEmpty ? const [] : [codexNoteRow(id, text, parent)];
    case 'commandExecution':
      return [
        CodexActivityEvent(codexCommandActivity(id, item, parent: parent)),
      ];
    case 'webSearch':
      return [
        codexWebSearchRow(id, item, completed: completed, parent: parent),
      ];
    case 'mcpToolCall':
      return [codexMcpRow(id, item, parent)];
    case 'dynamicToolCall':
      final tool = '${item['tool'] ?? 'tool'}';
      return [
        CodexActivityEvent(
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
        ),
      ];
    case 'collabAgentToolCall':
      return [
        codexCollabRow(
          id,
          item,
          agents: agents,
          parent: parent,
          helper: helper,
        ),
      ];
    case 'imageView':
      return [
        codexStepRow(
          id,
          'Looked at ${item['path'] ?? 'an image'}',
          tool: 'Image',
          parent: parent,
        ),
      ];
    case 'imageGeneration':
      return [
        CodexActivityEvent(
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
        ),
      ];
    case 'sleep':
      final ms = item['durationMs'];
      final seconds = ms is num ? (ms / 1000).round() : null;
      return [
        codexStepRow(
          id,
          seconds == null ? 'Waited a moment' : 'Waited ${seconds}s',
          tool: 'Wait',
          parent: parent,
        ),
      ];
    case 'enteredReviewMode':
      return [
        codexStepRow(
          id,
          'Started a review',
          tool: 'Review',
          request: codexPayloadText(item['review']),
          parent: parent,
        ),
      ];
    case 'exitedReviewMode':
      return [
        codexStepRow(
          id,
          'Finished the review',
          tool: 'Review',
          result: codexPayloadText(item['review']),
          parent: parent,
        ),
      ];
    case 'contextCompaction':
      return [
        codexStepRow(
          id,
          'Made room in the conversation',
          tool: 'Compact',
          parent: parent,
        ),
      ];
    case 'fileChange':
      return codexFileChangeEvents(id, item, parent: parent);
    // `userMessage` is the prompt this app just sent; `hookPrompt` is a hook's
    // and `subAgentActivity` is the bookkeeping behind the collab rows above.
    // None is worth a row.
    default:
      return const [];
  }
}

/// This protocol spells its lifecycle in camelCase (`inProgress`, `completed`,
/// `failed`, `declined`) where the old one used snake_case — a rename that would
/// otherwise show every finished command as still running.
AgentActivityStatus codexItemStatus(Object? raw) => switch (raw) {
  'completed' => AgentActivityStatus.done,
  'failed' || 'declined' => AgentActivityStatus.failed,
  _ => AgentActivityStatus.running,
};

/// A tool payload as text: a string as it stands, anything structured
/// pretty-printed as JSON, null for absent. (It printed Dart's own `{a: b}`
/// for a map, which is neither the payload nor anything a person reads.)
String? codexPayloadText(Object? raw) => switch (raw) {
  null => null,
  final String text => text,
  _ => const JsonEncoder.withIndent('  ').convert(raw),
};
