/// A Codex command, named by what it did.
///
/// The app-server parses every shell command it runs into `commandActions` —
/// `read` (a file, by name and path), `listFiles`, `search` (a query, in a
/// path) or `unknown` — and Codex's own VS Code panel draws those instead of
/// the command line, one entry per action (`cy()` in its webview). Here a
/// command stays one row, because a step is one call with one output, but
/// when every action it took is the same kind of looking the row says so —
/// "Read · conventions.md", not `cd /repo && sed -n '1,200p' …` — in the words
/// and with the glyph a Claude row doing the same thing has.
///
/// Estimated over a month of this app's Codex turns, the way the parser reads
/// a command: about one in six is a pure read, search or listing (169, 14 and
/// 9 of 1,105). The rest — `hermes cron …`, `osascript`, pipelines that do
/// several things — keep their command line, which is what a person needs to
/// see for those.
library;

import '../../core/folder_name.dart';
import 'agent_event.dart';
import 'codex_app_server_items.dart' show codexItemStatus;

/// One parsed action: its kind as the app-server names it, and what it was
/// about.
typedef CodexCommandAction = ({String type, String subject});

/// The row a `commandExecution` item becomes.
AgentActivity codexCommandActivity(
  String id,
  Map<String, dynamic> item, {
  String? parent,
}) {
  final command = '${item['command'] ?? ''}';
  // A declined command did nothing, so what it would have looked at is not
  // what happened — its command line is. The extension falls back the same
  // way.
  final named = item['status'] == 'declined'
      ? null
      : _named(codexCommandActions(item['commandActions']));
  return AgentActivity(
    id: id,
    kind: named == null ? AgentActivityKind.command : AgentActivityKind.tool,
    label: named?.label ?? (command.isEmpty ? 'command' : command),
    status: codexItemStatus(item['status']),
    tool: named?.tool ?? 'Shell',
    request: clipToolPayload(command),
    result: clipToolPayload('${item['aggregatedOutput'] ?? ''}'),
    parent: parent,
  );
}

/// The actions of a `commandExecution` item, read leniently: an entry the app
/// can't read counts as `unknown`, which keeps the command line on the row.
List<CodexCommandAction> codexCommandActions(Object? raw) => [
  if (raw is List)
    for (final entry in raw) _action(entry),
];

CodexCommandAction _action(Object? entry) {
  if (entry is! Map) return (type: 'unknown', subject: '');
  return switch (entry['type']) {
    'read' => (type: 'read', subject: _readSubject(entry)),
    'search' => (type: 'search', subject: _searchSubject(entry)),
    'listFiles' => (type: 'listFiles', subject: _tail(entry['path'])),
    _ => (type: 'unknown', subject: ''),
  };
}

/// The file read: its name as the action gives it, else the end of its path.
String _readSubject(Map<Object?, Object?> action) {
  final name = '${action['name'] ?? ''}'.trim();
  return name.isNotEmpty ? name : _tail(action['path']);
}

/// What was searched for, and in which folder when the action says.
String _searchSubject(Map<Object?, Object?> action) {
  final query = '${action['query'] ?? ''}'.trim();
  final where = _tail(action['path']);
  return [
    if (query.isNotEmpty) query,
    if (where.isNotEmpty) 'in $where',
  ].join(' ');
}

String _tail(Object? path) => path is String ? folderName(path.trim()) : '';

/// What every action in [actions] did, as a row's tool and label — or null
/// when they didn't all do the same kind of looking, or one did something the
/// app-server couldn't name.
({String tool, String label})? _named(List<CodexCommandAction> actions) {
  if (actions.isEmpty) return null;
  final type = actions.first.type;
  if (type == 'unknown' || actions.any((action) => action.type != type)) {
    return null;
  }
  final tool = switch (type) {
    'read' => 'Read',
    'search' => 'Search',
    _ => 'List',
  };
  final subjects = {
    for (final action in actions)
      if (action.subject.isNotEmpty) action.subject,
  };
  return (
    tool: tool,
    label: subjects.isEmpty ? tool : '$tool · ${subjects.join(', ')}',
  );
}
