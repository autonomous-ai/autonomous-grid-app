import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/projects/logic/project.dart';

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_projects_test');
    file = File('${tmp.path}/projects.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        projectsStoreProvider.overrideWithValue(ProjectsStore(file: file)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('folderName is what a person calls the folder', () {
    expect(folderName('/Users/me/WorkPlace/web-v16'), 'web-v16');
    expect(folderName('/Users/me/notes/'), 'notes');
  });

  test('adding a folder names the project after it and persists', () {
    final c = container();

    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    expect(project.name, 'notes');
    expect(c.read(projectsProvider), hasLength(1));
    // A fresh controller (next launch) sees the same project.
    expect(container().read(projectsProvider).single.path, project.path);
  });

  test('adding the same folder twice keeps one project, not two', () {
    final c = container();
    final first = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    final again = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    expect(again.id, first.id);
    expect(c.read(projectsProvider), hasLength(1));
  });

  test('removing a project leaves the folder on disk alone', () async {
    final folder = await Directory('${tmp.path}/keep-me').create();
    final c = container();
    final project = c.read(projectsProvider.notifier).add(folder.path);

    c.read(projectsProvider.notifier).remove(project.id);

    expect(c.read(projectsProvider), isEmpty);
    expect(folder.existsSync(), isTrue);
  });

  test('a project whose folder was deleted still lists — but says so, rather '
      'than vanishing with its chats', () async {
    final folder = await Directory('${tmp.path}/gone').create();
    final c = container();
    c.read(projectsProvider.notifier).add(folder.path);
    await folder.delete();

    final project = c.read(projectsProvider).single;
    expect(project.exists, isFalse);
  });

  test('a corrupt store reads as no projects instead of throwing', () {
    file.writeAsStringSync('{ not json');
    expect(ProjectsStore(file: file).load(), isEmpty);
  });

  test('projectByIdProvider gives null for a project that was removed — a chat '
      'can outlive its project', () {
    final c = container();
    expect(c.read(projectByIdProvider('nope')), isNull);
    expect(c.read(projectByIdProvider(null)), isNull);
  });

  test('a project starts with no agent rules', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    expect(project.instructions, isEmpty);
  });

  test('agent rules are trimmed, persisted, and reloaded next launch', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c
        .read(projectsProvider.notifier)
        .setInstructions(project.id, '  Answer in Vietnamese.  ');

    expect(
      c.read(projectByIdProvider(project.id))?.instructions,
      'Answer in Vietnamese.',
    );
    // Survives a relaunch (a fresh controller reading the same store).
    expect(
      container().read(projectsProvider).single.instructions,
      'Answer in Vietnamese.',
    );
  });

  test('blank agent rules clear them and drop out of the saved file', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    c.read(projectsProvider.notifier).setInstructions(project.id, 'Be brief.');

    c.read(projectsProvider.notifier).setInstructions(project.id, '   ');

    expect(c.read(projectByIdProvider(project.id))?.instructions, isEmpty);
    expect(file.readAsStringSync(), isNot(contains('instructions')));
  });

  test('setting rules on a missing project is a no-op, not a crash', () {
    final c = container();
    c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).setInstructions('nope', 'Hi.');

    expect(c.read(projectsProvider).single.instructions, isEmpty);
  });

  test(
    'renaming changes the label, keeps the folder, and reloads next launch',
    () {
      final c = container();
      final project = c
          .read(projectsProvider.notifier)
          .add('${tmp.path}/notes');

      c.read(projectsProvider.notifier).rename(project.id, '  My notes  ');

      expect(c.read(projectByIdProvider(project.id))?.name, 'My notes');
      // Path (its identity) never moves, and the new name survives a relaunch.
      expect(c.read(projectByIdProvider(project.id))?.path, project.path);
      expect(container().read(projectsProvider).single.name, 'My notes');
    },
  );

  test('a blank rename is ignored — a nameless row can\'t be told apart', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).rename(project.id, '   ');

    expect(c.read(projectByIdProvider(project.id))?.name, 'notes');
  });

  test('pinning persists and reloads, and unpinning drops out of the file', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    expect(project.pinned, isFalse);

    c.read(projectsProvider.notifier).setPinned(project.id, true);
    expect(c.read(projectByIdProvider(project.id))?.pinned, isTrue);
    expect(container().read(projectsProvider).single.pinned, isTrue);

    c.read(projectsProvider.notifier).setPinned(project.id, false);
    expect(file.readAsStringSync(), isNot(contains('pinned')));
  });

  test(
    'sortedProjects floats pinned to the top, keeping order within groups',
    () {
      final c = container();
      final a = c.read(projectsProvider.notifier).add('${tmp.path}/a');
      c.read(projectsProvider.notifier).add('${tmp.path}/b');
      final cc = c.read(projectsProvider.notifier).add('${tmp.path}/c');

      // Pin the last one; it should jump ahead of the earlier, unpinned two.
      c.read(projectsProvider.notifier).setPinned(cc.id, true);

      final order = c.read(sortedProjectsProvider).map((p) => p.name).toList();
      expect(order, ['c', 'a', 'b']);
      // The stored order is untouched — only the display view reorders.
      expect(c.read(projectsProvider).map((p) => p.name).toList(), [
        'a',
        'b',
        'c',
      ]);
      expect(a.pinned, isFalse);
    },
  );
}
