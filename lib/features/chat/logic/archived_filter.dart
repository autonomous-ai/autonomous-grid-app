import '../../projects/logic/project.dart';
import 'conversation.dart';

/// How the Archived screen orders its rows.
enum ArchivedSort {
  /// When the chat was put away — the screen's default, and the order the user
  /// filed them in.
  archivedNewest('Recently archived'),

  /// Oldest filed first, for clearing out the bottom of the pile.
  archivedOldest('Oldest archived'),

  /// When the chat was last talked in, which is not the same as when it was
  /// archived — an old conversation can be filed away today.
  updatedNewest('Recently updated'),

  /// A–Z, for finding a chat you remember the name of.
  titleAsc('Name (A–Z)');

  const ArchivedSort(this.label);

  /// What the sort control shows for this option.
  final String label;
}

/// Which archived chats the screen lists, before [ArchivedQuery.projectId]
/// narrows it further.
enum ArchivedScope {
  all('All chats'),

  /// Chats that belong to no project — the "Chats" group in the sidebar.
  looseOnly('Outside projects'),

  /// Chats that belong to some project, whichever it is.
  projectsOnly('In a project');

  const ArchivedScope(this.label);

  final String label;
}

/// Everything the Archived screen's controls add up to: the text typed in the
/// search box, the scope and project filters, and the sort.
///
/// A value type so the screen holds one field of state instead of four, and so
/// the filtering can be tested without building a widget.
class ArchivedQuery {
  const ArchivedQuery({
    this.text = '',
    this.scope = ArchivedScope.all,
    this.projectId,
    this.sort = ArchivedSort.archivedNewest,
  });

  final String text;
  final ArchivedScope scope;

  /// Restrict to one project. Null means "any", and it is only meaningful
  /// alongside [ArchivedScope.all] or [ArchivedScope.projectsOnly].
  final String? projectId;

  final ArchivedSort sort;

  ArchivedQuery copyWith({
    String? text,
    ArchivedScope? scope,
    String? projectId,
    bool clearProjectId = false,
    ArchivedSort? sort,
  }) => ArchivedQuery(
    text: text ?? this.text,
    scope: scope ?? this.scope,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    sort: sort ?? this.sort,
  );

  /// True when anything is narrowing the list — the screen uses this to tell
  /// "you have no archived chats" apart from "nothing matched", which are
  /// different messages and only one of them is worth an action.
  bool get isFiltering =>
      text.trim().isNotEmpty || scope != ArchivedScope.all || projectId != null;
}

/// Applies [query] to [archived] — filter, then sort.
///
/// Searching looks at the title *and* the transcript: a chat is often
/// remembered by something said in it rather than by the name the agent gave
/// it, and an archived chat is exactly the one whose title the user has
/// forgotten.
List<Conversation> filterArchived(
  List<Conversation> archived,
  ArchivedQuery query,
) {
  final needle = query.text.trim().toLowerCase();
  final matches = [
    for (final c in archived)
      if (_inScope(c, query) && _matchesText(c, needle)) c,
  ];
  return matches..sort(_comparatorFor(query.sort));
}

bool _inScope(Conversation chat, ArchivedQuery query) {
  final belongsToProject = chat.projectId != null;
  final scopeOk = switch (query.scope) {
    ArchivedScope.all => true,
    ArchivedScope.looseOnly => !belongsToProject,
    ArchivedScope.projectsOnly => belongsToProject,
  };
  if (!scopeOk) return false;
  final wanted = query.projectId;
  return wanted == null || chat.projectId == wanted;
}

bool _matchesText(Conversation chat, String needle) {
  if (needle.isEmpty) return true;
  if (chat.title.toLowerCase().contains(needle)) return true;
  for (final message in chat.messages) {
    if (message.text.toLowerCase().contains(needle)) return true;
  }
  return false;
}

int Function(Conversation, Conversation) _comparatorFor(ArchivedSort sort) =>
    switch (sort) {
      // Every chat here is archived, so `archivedAt` is non-null — but read it
      // defensively anyway rather than `!`, since a hand-edited file reaching
      // this list must not crash the screen.
      ArchivedSort.archivedNewest => (a, b) => _archivedAt(
        b,
      ).compareTo(_archivedAt(a)),
      ArchivedSort.archivedOldest => (a, b) => _archivedAt(
        a,
      ).compareTo(_archivedAt(b)),
      ArchivedSort.updatedNewest => (a, b) => b.updatedAt.compareTo(
        a.updatedAt,
      ),
      ArchivedSort.titleAsc => (a, b) => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
    };

DateTime _archivedAt(Conversation chat) =>
    chat.archivedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

/// One project's archived chats, for the grouped list. [project] is null for
/// the bucket holding chats that belong to no project.
class ArchivedGroup {
  const ArchivedGroup({required this.project, required this.chats});

  final Project? project;
  final List<Conversation> chats;

  /// What the group header shows. A chat whose project has since been removed
  /// still carries its id, so it lands in the loose bucket rather than
  /// vanishing from a screen whose whole job is to account for every chat.
  String get label => project?.name ?? 'Outside projects';

  Set<String> get ids => {for (final c in chats) c.id};
}

/// Buckets [chats] by project, preserving the order [filterArchived] put them
/// in. Projects come first in the order the app lists them, then the loose
/// chats — matching the sidebar, where projects sit above "Chats".
///
/// Empty groups are dropped, so the screen never shows a header with no rows
/// under it.
List<ArchivedGroup> groupArchivedByProject(
  List<Conversation> chats,
  List<Project> projects,
) {
  final byId = {for (final p in projects) p.id: p};
  final groups = <ArchivedGroup>[];
  for (final project in projects) {
    final owned = [
      for (final c in chats)
        if (c.projectId == project.id) c,
    ];
    if (owned.isNotEmpty) {
      groups.add(ArchivedGroup(project: project, chats: owned));
    }
  }
  final loose = [
    for (final c in chats)
      if (c.projectId == null || !byId.containsKey(c.projectId)) c,
  ];
  if (loose.isNotEmpty) {
    groups.add(ArchivedGroup(project: null, chats: loose));
  }
  return groups;
}
