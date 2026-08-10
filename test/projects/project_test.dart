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
    // Windows hands out backslashes; splitting on '/' alone would name the
    // project after its whole absolute path.
    expect(folderName(r'C:\Users\me\web-v16'), 'web-v16');
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

  test('a project whose folder was deleted still lists, rather than vanishing '
      'with its chats', () async {
    final folder = await Directory('${tmp.path}/gone').create();
    final c = container();
    c.read(projectsProvider.notifier).add(folder.path);
    await folder.delete();

    // That the folder is gone is reported separately, off the UI thread — see
    // project_folder_status_test. The list's job is to keep the project.
    expect(c.read(projectsProvider).single.path, folder.path);
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

  test('a project starts on the app default assistant and model', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    expect(project.agent, isNull);
    expect(project.model, isNull);
  });

  test('the assistant and model picked in a project persist and reload next '
      'launch — the whole point of steering one project', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).setAgent(project.id, 'codex');
    c.read(projectsProvider.notifier).setModel(project.id, ' qwen3-coder ');

    final reloaded = container().read(projectsProvider).single;
    expect(reloaded.agent, 'codex');
    expect(reloaded.model, 'qwen3-coder');
  });

  test('clearing them puts the project back on the app default and drops them '
      'out of the saved file', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    c.read(projectsProvider.notifier).setAgent(project.id, 'codex');
    c.read(projectsProvider.notifier).setModel(project.id, 'qwen3-coder');

    c.read(projectsProvider.notifier).setAgent(project.id, null);
    c.read(projectsProvider.notifier).setModel(project.id, null);

    expect(c.read(projectByIdProvider(project.id))?.agent, isNull);
    expect(c.read(projectByIdProvider(project.id))?.model, isNull);
    expect(file.readAsStringSync(), isNot(contains('agent')));
    expect(file.readAsStringSync(), isNot(contains('model')));
  });

  test('steering one project leaves the others alone', () {
    final c = container();
    final steered = c.read(projectsProvider.notifier).add('${tmp.path}/api');
    final other = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).setAgent(steered.id, 'codex');

    expect(c.read(projectByIdProvider(other.id))?.agent, isNull);
  });

  test('setting an assistant on a missing project is a no-op, not a crash', () {
    final c = container();
    c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).setAgent('nope', 'codex');

    expect(c.read(projectsProvider).single.agent, isNull);
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

  test(
    'create names the project, sets its rules, trims both, and persists',
    () {
      final c = container();

      final project = c
          .read(projectsProvider.notifier)
          .create(
            path: '${tmp.path}/notes',
            name: '  My notes  ',
            instructions: '  Answer in Vietnamese.  ',
          );

      expect(project.name, 'My notes');
      expect(project.instructions, 'Answer in Vietnamese.');
      // Survives a relaunch (a fresh controller reading the same store).
      final reloaded = container().read(projectsProvider).single;
      expect(reloaded.name, 'My notes');
      expect(reloaded.instructions, 'Answer in Vietnamese.');
    },
  );

  test('create with a blank name falls back to the folder name', () {
    final c = container();

    final project = c
        .read(projectsProvider.notifier)
        .create(path: '${tmp.path}/notes', name: '   ');

    expect(project.name, 'notes');
    expect(project.instructions, isEmpty);
  });

  test('create on a folder that is already a project returns it untouched, '
      'never a duplicate', () {
    final c = container();
    final first = c
        .read(projectsProvider.notifier)
        .create(path: '${tmp.path}/notes', name: 'First', instructions: 'Keep');

    final again = c
        .read(projectsProvider.notifier)
        .create(
          path: '${tmp.path}/notes',
          name: 'Second',
          instructions: 'Overwrite',
        );

    expect(again.id, first.id);
    expect(c.read(projectsProvider), hasLength(1));
    // Re-adding a folder must not clobber the rules already on it.
    expect(again.name, 'First');
    expect(again.instructions, 'Keep');
  });

  test('add is the bare form of create — folder name, no rules', () {
    final c = container();

    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    expect(project.name, 'notes');
    expect(project.instructions, isEmpty);
  });

  test('a project starts remembering nothing', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    expect(project.memory, isEmpty);
  });

  test('remembering a fact trims it, persists, and reloads next launch', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c
        .read(projectsProvider.notifier)
        .addMemory(project.id, '  The prod DB is read-only.  ');

    expect(c.read(projectByIdProvider(project.id))?.memory, [
      'The prod DB is read-only.',
    ]);
    expect(container().read(projectsProvider).single.memory, [
      'The prod DB is read-only.',
    ]);
  });

  test('the same fact is remembered once, not twice', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).addMemory(project.id, 'Ship to #eng');
    c.read(projectsProvider.notifier).addMemory(project.id, 'Ship to #eng');

    expect(c.read(projectByIdProvider(project.id))?.memory, ['Ship to #eng']);
  });

  test('a blank fact is not remembered', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).addMemory(project.id, '   ');

    expect(c.read(projectByIdProvider(project.id))?.memory, isEmpty);
  });

  test('forgetting a fact drops just that one, keeping the order', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    final notifier = c.read(projectsProvider.notifier);
    notifier.addMemory(project.id, 'one');
    notifier.addMemory(project.id, 'two');
    notifier.addMemory(project.id, 'three');

    notifier.removeMemoryAt(project.id, 1);

    expect(c.read(projectByIdProvider(project.id))?.memory, ['one', 'three']);
  });

  test('forgetting an out-of-range fact is a no-op, not a crash', () {
    final c = container();
    final project = c.read(projectsProvider.notifier).add('${tmp.path}/notes');
    c.read(projectsProvider.notifier).addMemory(project.id, 'only');

    c.read(projectsProvider.notifier).removeMemoryAt(project.id, 5);

    expect(c.read(projectByIdProvider(project.id))?.memory, ['only']);
  });

  test('remembering against a missing project is a no-op, not a crash', () {
    final c = container();
    c.read(projectsProvider.notifier).add('${tmp.path}/notes');

    c.read(projectsProvider.notifier).addMemory('nope', 'Hi.');

    expect(c.read(projectsProvider).single.memory, isEmpty);
  });

  test(
    'memory round-trips through JSON and drops out of the file when empty',
    () {
      final project = const Project(
        id: '1',
        name: 'notes',
        path: '/tmp/notes',
        memory: ['a', 'b'],
      );

      final reread = Project.fromJson(project.toJson().cast());
      expect(reread?.memory, ['a', 'b']);

      const empty = Project(id: '1', name: 'notes', path: '/tmp/notes');
      expect(empty.toJson().containsKey('memory'), isFalse);
    },
  );

  test(
    'loading memory skips blank and non-string entries, trimming the rest',
    () {
      final project = Project.fromJson({
        'id': '1',
        'path': '/tmp/notes',
        'memory': ['  keep  ', '', 42, null, 'also'],
      });
      expect(project?.memory, ['keep', 'also']);
    },
  );

  group('projectStandingBrief', () {
    Project make({String instructions = '', List<String> memory = const []}) =>
        Project(
          id: '1',
          name: 'notes',
          path: '/tmp/notes',
          instructions: instructions,
          memory: memory,
        );

    test('is empty when the project steers nothing, so a chat carries no '
        'preamble', () {
      expect(projectStandingBrief(make()), isEmpty);
    });

    test('is just the rules when there is no memory', () {
      expect(
        projectStandingBrief(make(instructions: 'Be brief.')),
        'Be brief.',
      );
    });

    test('lists the remembered facts as bullets when there are no rules', () {
      expect(
        projectStandingBrief(make(memory: ['A', 'B'])),
        'Remember about this project:\n- A\n- B',
      );
    });

    test(
      'joins rules then memory so the agent gets both on its first turn',
      () {
        expect(
          projectStandingBrief(make(instructions: 'Be brief.', memory: ['A'])),
          'Be brief.\n\nRemember about this project:\n- A',
        );
      },
    );
  });
}
