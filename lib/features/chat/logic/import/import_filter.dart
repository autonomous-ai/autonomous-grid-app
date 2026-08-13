import 'parsed_session.dart';
import 'session_import_controller.dart';

/// Which tool's sessions the list is showing.
enum ImportAgentFilter {
  all('All'),
  claude('Claude Code'),
  codex('Codex');

  const ImportAgentFilter(this.label);

  final String label;

  /// Whether [agent] belongs in this filter.
  bool covers(ImportedAgent agent) => switch (this) {
    ImportAgentFilter.all => true,
    ImportAgentFilter.claude => agent == ImportedAgent.claude,
    ImportAgentFilter.codex => agent == ImportedAgent.codex,
  };
}

/// The filter that shows only this tool's sessions — what picking a source
/// card sets, so "which tool" is a choice already made rather than a control
/// repeated above the list.
extension ImportedAgentFilter on ImportedAgent {
  ImportAgentFilter get filter => switch (this) {
    ImportedAgent.claude => ImportAgentFilter.claude,
    ImportedAgent.codex => ImportAgentFilter.codex,
  };
}

/// What the import screen's controls are set to.
class ImportQuery {
  const ImportQuery({
    this.text = '',
    this.agent = ImportAgentFilter.all,
    this.hideImported = false,
  });

  /// Matched against the session's title and the name of the folder it ran in
  /// — the two things a user remembers a conversation by.
  final String text;

  final ImportAgentFilter agent;

  /// Drop the rows there is nothing left to do with.
  ///
  /// Off by default: a list that hid what it had already done would look like
  /// sessions were going missing, and "did I import that one?" is the question
  /// this screen exists to answer.
  final bool hideImported;

  ImportQuery copyWith({
    String? text,
    ImportAgentFilter? agent,
    bool? hideImported,
  }) => ImportQuery(
    text: text ?? this.text,
    agent: agent ?? this.agent,
    hideImported: hideImported ?? this.hideImported,
  );
}

/// The rows of [all] that [query] keeps, in the order they came in — newest
/// first, as the scan sorted them.
List<ImportableSession> filterImportable(
  List<ImportableSession> all,
  ImportQuery query,
) {
  final needle = query.text.trim().toLowerCase();
  return [
    for (final row in all)
      if (query.agent.covers(row.session.agent) &&
          !(query.hideImported && row.status == ImportStatus.imported) &&
          _matches(row, needle))
        row,
  ];
}

/// How many of [all] came from [agent] — the count on each filter segment, so
/// the segments say what is behind them before they are clicked.
int countFor(List<ImportableSession> all, ImportAgentFilter agent) {
  var count = 0;
  for (final row in all) {
    if (agent.covers(row.session.agent)) count++;
  }
  return count;
}

bool _matches(ImportableSession row, String needle) {
  if (needle.isEmpty) return true;
  final session = row.session;
  return session.title.toLowerCase().contains(needle) ||
      session.folderName.toLowerCase().contains(needle) ||
      (session.workdir?.toLowerCase().contains(needle) ?? false);
}
