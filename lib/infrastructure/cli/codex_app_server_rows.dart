/// The rows one Codex `ThreadItem` becomes — pulled out of the item switch
/// so that file stays a switch and this one stays the vocabulary.
library;

import 'agent_event.dart';
import 'codex_agent_service.dart';
import 'codex_app_server_items.dart' show codexItemStatus, codexPayloadText;
import 'tool_subject.dart';

/// What Codex does to a helper agent, in the user's words — every
/// `CollabAgentTool` the app-server names (0.155). The panel files
/// `sendMessage` and `followupTask` under the same "Messaged" as `sendInput`,
/// so they share its words here.
const Map<String, String> kCodexCollabLabels = {
  'spawnAgent': 'Started a helper agent',
  'sendInput': 'Sent a message to a helper agent',
  'sendMessage': 'Sent a message to a helper agent',
  'followupTask': 'Sent a message to a helper agent',
  'resumeAgent': 'Resumed a helper agent',
  'wait': 'Waited for helper agents',
  'interruptAgent': 'Interrupted a helper agent',
  'listAgents': 'Listed helper agents',
  'closeAgent': 'Closed a helper agent',
};

/// A helper's `CollabAgentStatus`, in the words the rest of the feed uses.
const Map<String, String> _kCollabAgentStates = {
  'pendingInit': 'starting',
  'running': 'running',
  'interrupted': 'interrupted',
  'completed': 'finished',
  'errored': 'hit an error',
  'shutdown': 'closed',
  'notFound': 'not found',
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
  return CodexActivityEvent(
    AgentActivity(
      id: id,
      kind: AgentActivityKind.tool,
      label: kCodexCollabLabels[tool] ?? 'Helper agent: $tool',
      status: status,
      tool: 'Helper agent',
      request: clipToolPayload(codexPayloadText(item['prompt'])),
      result: clipToolPayload(codexCollabStatesText(item['agentsStates'])),
      parent: parent,
    ),
  );
}

/// Where each helper a call touched stands — "019a…: finished", then the
/// message it left, if any — or null when the call reported none.
///
/// Each state is a `CollabAgentState` map, `{status, message}`. Interpolated
/// whole it printed as Dart's own `{status: completed, message: …}`, the same
/// trap [codexPayloadText] was written to close for every other payload.
String? codexCollabStatesText(Object? states) {
  if (states is! Map || states.isEmpty) return null;
  return [
    for (final MapEntry(:key, :value) in states.entries)
      _collabStateLine('$key', value),
  ].join('\n\n');
}

String _collabStateLine(String agent, Object? state) {
  if (state is! Map) return '$agent: ${codexPayloadText(state) ?? ''}'.trim();
  final raw = '${state['status'] ?? ''}';
  final words = _kCollabAgentStates[raw] ?? raw;
  final message = '${state['message'] ?? ''}'.trim();
  final line = '$agent: $words';
  return message.isEmpty ? line : '$line\n$message';
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

/// A connector's call, said the way a Claude connector row says it —
/// `server · tool · subject` — and named `mcp__server__tool`, so it takes the
/// connector glyph and title the feed gives every lane's MCP calls. It read as
/// the bare tool name ("impact"), with its answer a dump of the result map.
CodexEvent codexMcpRow(String id, Map<String, dynamic> item, String? parent) {
  final server = '${item['server'] ?? ''}'.trim();
  final tool = '${item['tool'] ?? ''}'.trim();
  final arguments = item['arguments'];
  final label = connectorLabel(
    server: server,
    tool: tool,
    input: arguments is Map ? arguments.cast<String, dynamic>() : const {},
  );
  return CodexActivityEvent(
    AgentActivity(
      id: id,
      kind: AgentActivityKind.tool,
      label: label.isEmpty ? 'tool' : label,
      status: codexItemStatus(item['status']),
      tool: 'mcp__${server}__$tool',
      request: clipToolPayload(codexPayloadText(arguments)),
      result: clipToolPayload(
        codexMcpResultText(item['result'] ?? item['error']),
      ),
      parent: parent,
    ),
  );
}

/// A connector's answer as text: the text of an MCP result's content blocks —
/// what the tool said — else the whole thing, pretty-printed.
String? codexMcpResultText(Object? result) {
  if (result is Map && result['content'] is List) {
    final text = codexTextLines(result['content']);
    if (text.isNotEmpty) return text;
  }
  return codexPayloadText(result);
}

/// A web search, named by what it looked for, the page it opened, or the text
/// it looked for on a page.
///
/// The item carries **no status** — the schema gives it `action` and `query`
/// and nothing else — so reading one, as every other row does, left each web
/// search running until the turn ended and then settled as unknown. It is
/// running while the item is, and done once it [completed].
CodexEvent codexWebSearchRow(
  String id,
  Map<String, dynamic> item, {
  required bool completed,
  String? parent,
}) {
  final about = codexWebSearchSubject(item);
  return CodexActivityEvent(
    AgentActivity(
      id: id,
      kind: AgentActivityKind.web,
      label: about.isEmpty ? 'Web search' : about,
      status: completed
          ? AgentActivityStatus.done
          : AgentActivityStatus.running,
      tool: 'Web search',
      request: clipToolPayload(about),
      parent: parent,
    ),
  );
}

/// What a web search was about, from its `action` — a query, a page opened,
/// or a pattern looked for on a page — with the item's own `query` as the
/// fallback.
String codexWebSearchSubject(Map<String, dynamic> item) {
  final fromAction = switch (item['action']) {
    {'type': 'openPage', 'url': final String url} => url,
    {
      'type': 'findInPage',
      'pattern': final String pattern,
      'url': final String url,
    } =>
      '"$pattern" in $url',
    {'type': 'search', 'query': final String query} => query,
    {'type': 'search', 'queries': final List<Object?> queries} =>
      queries.whereType<String>().join(', '),
    _ => '',
  };
  final fallback = '${item['query'] ?? ''}';
  return (fromAction.trim().isNotEmpty ? fromAction : fallback).trim();
}
