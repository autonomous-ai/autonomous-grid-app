import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/archived_filter.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/projects/logic/project.dart';

Conversation _chat({
  required String id,
  String title = 'Chat',
  String? projectId,
  DateTime? archivedAt,
  DateTime? updatedAt,
  List<String> said = const [],
}) => Conversation(
  id: id,
  title: title,
  model: 'm',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt ?? DateTime(2026, 1, 1),
  projectId: projectId,
  archivedAt: archivedAt ?? DateTime(2026, 6, 1),
  messages: [
    for (final text in said) ChatMessage(role: ChatRole.user, text: text),
  ],
);

Project _project(String id, String name) =>
    Project(id: id, name: name, path: '/tmp/$id');

void main() {
  group('filterArchived — search', () {
    test('matches a title case-insensitively', () {
      final chats = [
        _chat(id: 'a', title: 'Deploy the relay'),
        _chat(id: 'b', title: 'Dinner ideas'),
      ];
      final found = filterArchived(chats, const ArchivedQuery(text: 'DEPLOY'));
      expect(found.map((c) => c.id), ['a']);
    });

    test('matches text inside the transcript, not just the title', () {
      // The reason search reads messages: an archived chat is the one whose
      // title the user has forgotten, but they remember what was said in it.
      final chats = [
        _chat(id: 'a', title: 'Untitled', said: ['how do I rotate a token?']),
        _chat(id: 'b', title: 'Untitled 2', said: ['what is for lunch']),
      ];
      final found = filterArchived(chats, const ArchivedQuery(text: 'rotate'));
      expect(found.map((c) => c.id), ['a']);
    });

    test('blank and whitespace-only queries match everything', () {
      final chats = [_chat(id: 'a'), _chat(id: 'b')];
      expect(filterArchived(chats, const ArchivedQuery()).length, 2);
      expect(filterArchived(chats, const ArchivedQuery(text: '   ')).length, 2);
    });
  });

  group('filterArchived — scope and project', () {
    final chats = [
      _chat(id: 'loose'),
      _chat(id: 'inWeb', projectId: 'web'),
      _chat(id: 'inApi', projectId: 'api'),
    ];

    test('looseOnly keeps just the chats outside a project', () {
      final found = filterArchived(
        chats,
        const ArchivedQuery(scope: ArchivedScope.looseOnly),
      );
      expect(found.map((c) => c.id), ['loose']);
    });

    test('projectsOnly drops the loose chats', () {
      final found = filterArchived(
        chats,
        const ArchivedQuery(scope: ArchivedScope.projectsOnly),
      );
      expect(found.map((c) => c.id).toSet(), {'inWeb', 'inApi'});
    });

    test('a project filter narrows to that one project', () {
      final found = filterArchived(
        chats,
        const ArchivedQuery(projectId: 'web'),
      );
      expect(found.map((c) => c.id), ['inWeb']);
    });
  });

  group('filterArchived — sort', () {
    final chats = [
      _chat(
        id: 'mid',
        title: 'Beta',
        archivedAt: DateTime(2026, 6, 10),
        updatedAt: DateTime(2026, 5, 1),
      ),
      _chat(
        id: 'newest',
        title: 'Charlie',
        archivedAt: DateTime(2026, 6, 20),
        updatedAt: DateTime(2026, 1, 1),
      ),
      _chat(
        id: 'oldest',
        title: 'Alpha',
        archivedAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 30),
      ),
    ];

    test('defaults to most recently archived first', () {
      final found = filterArchived(chats, const ArchivedQuery());
      expect(found.map((c) => c.id), ['newest', 'mid', 'oldest']);
    });

    test('archivedOldest reverses it', () {
      final found = filterArchived(
        chats,
        const ArchivedQuery(sort: ArchivedSort.archivedOldest),
      );
      expect(found.map((c) => c.id), ['oldest', 'mid', 'newest']);
    });

    test('updatedNewest sorts by last talked in, not by when archived', () {
      // 'oldest' was archived first but talked in most recently — the two
      // orders are genuinely different, which is why both are offered.
      final found = filterArchived(
        chats,
        const ArchivedQuery(sort: ArchivedSort.updatedNewest),
      );
      expect(found.map((c) => c.id), ['oldest', 'mid', 'newest']);
    });

    test('titleAsc sorts by name', () {
      final found = filterArchived(
        chats,
        const ArchivedQuery(sort: ArchivedSort.titleAsc),
      );
      expect(found.map((c) => c.title), ['Alpha', 'Beta', 'Charlie']);
    });
  });

  group('groupArchivedByProject', () {
    test('buckets by project, loose chats last, empty groups dropped', () {
      final projects = [_project('web', 'web'), _project('api', 'api')];
      final chats = [_chat(id: 'l1'), _chat(id: 'w1', projectId: 'web')];
      final groups = groupArchivedByProject(chats, projects);
      // 'api' has no archived chats, so it gets no header.
      expect(groups.map((g) => g.label), ['web', 'Outside projects']);
      expect(groups.first.ids, {'w1'});
      expect(groups.last.ids, {'l1'});
    });

    test('a chat whose project is gone falls into the loose bucket', () {
      // It must still be listed: this screen has to account for every archived
      // chat, or one becomes unreachable.
      final chats = [_chat(id: 'orphan', projectId: 'deleted')];
      final groups = groupArchivedByProject(chats, [_project('web', 'web')]);
      expect(groups.map((g) => g.label), ['Outside projects']);
      expect(groups.single.ids, {'orphan'});
    });
  });

  group('ArchivedQuery', () {
    test('isFiltering is false only when nothing narrows the list', () {
      expect(const ArchivedQuery().isFiltering, isFalse);
      expect(const ArchivedQuery(text: '  ').isFiltering, isFalse);
      expect(const ArchivedQuery(text: 'x').isFiltering, isTrue);
      expect(
        const ArchivedQuery(scope: ArchivedScope.looseOnly).isFiltering,
        isTrue,
      );
      expect(const ArchivedQuery(projectId: 'web').isFiltering, isTrue);
    });

    test('clearProjectId removes the filter that copyWith cannot unset', () {
      const query = ArchivedQuery(projectId: 'web');
      expect(query.copyWith(clearProjectId: true).projectId, isNull);
      // Without the flag, passing null means "leave it alone".
      expect(query.copyWith().projectId, 'web');
    });
  });
}
