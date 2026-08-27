/// The rows one Codex `ThreadItem` becomes — pulled out of the item switch
/// so that file stays a switch and this one stays the vocabulary.
library;

import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_items.dart' show codexItemStatus, codexPayloadText;

/// The five things Codex does to a helper agent, in the user's words.
const Map<String, String> kCodexCollabLabels = {
  'spawnAgent': 'Started a helper agent',
  'sendInput': 'Sent a message to a helper agent',
  'resumeAgent': 'Resumed a helper agent',
  'wait': 'Waited for helper agents',
  'closeAgent': 'Closed a helper agent',
};

/// A `collabAgentToolCall`: one row per call, titled by what it did, with the
/// helpers' states as its result once known.
///
/// A completed spawn is where a helper thread becomes attributable: its id is
/// recorded against this row, so every item that thread sends afterwards nests
/// here. Only a spawn *this* thread made is recorded — a helper spawning
/// helpers of its own is bookkeeping the parent's rows do not need.
CodexEvent codexCollabRow(
  String id,
  Map<String, dynamic> item, {
  required Map<String, String> agents,
  required String? parent,
  required bool helper,
}) {
  final tool = '${item['tool'] ?? ''}';
  final status = codexItemStatus(item['status']);
  if (!helper && tool == 'spawnAgent' && status == AgentActivityStatus.done) {
    final receivers = item['receiverThreadIds'];
    if (receivers is List) {
      for (final receiver in receivers) {
        if (receiver is String && receiver.isNotEmpty) agents[receiver] = id;
      }
    }
  }
  final states = item['agentsStates'];
  return CodexActivityEvent(
    AgentActivity(
      id: id,
      kind: AgentActivityKind.tool,
      label: kCodexCollabLabels[tool] ?? 'Helper agent: $tool',
      status: status,
      tool: 'Helper agent',
      request: clipToolPayload(codexPayloadText(item['prompt'])),
      result: clipToolPayload(
        states is Map && states.isNotEmpty
            ? [
                for (final entry in states.entries)
                  '${entry.key}: ${entry.value}',
              ].join('\n')
            : null,
      ),
      parent: parent,
    ),
  );
}

/// One passage the model wrote to itself — a thought, a plan, a helper's
/// report. Filed as thinking because that is what it is from the user's side,
/// and the feed already draws that kind behind the fold.
CodexEvent codexNoteRow(String id, String text, String? parent) =>
    CodexActivityEvent(
      AgentActivity(
        id: id,
        kind: AgentActivityKind.thinking,
        label: text.trim(),
        status: AgentActivityStatus.done,
        parent: parent,
      ),
    );

/// A step that is over by the time it is reported.
CodexEvent codexStepRow(
  String id,
  String label, {
  required String tool,
  String? request,
  String? result,
  String? parent,
}) => CodexActivityEvent(
  AgentActivity(
    id: id,
    kind: AgentActivityKind.tool,
    label: label,
    status: AgentActivityStatus.done,
    tool: tool,
    request: clipToolPayload(request),
    result: clipToolPayload(result),
    parent: parent,
  ),
);

/// The text of a list of strings — or of content items carrying `text` —
/// joined as paragraphs; empty for anything else.
String codexTextLines(Object? raw) {
  if (raw is! List) return '';
  return [
    for (final entry in raw)
      if (entry is String)
        entry.trim()
      else if (entry is Map && entry['text'] is String)
        '${entry['text']}'.trim(),
  ].where((line) => line.isNotEmpty).join('\n\n');
}
