import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/projects/logic/project_tasks_store.dart';

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_project_tasks_test');
    file = File('${tmp.path}/project_tasks.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        projectTasksStoreProvider.overrideWithValue(
          ProjectTasksStore(file: file),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a task tied to a project persists and reloads next launch', () {
    final c = container();

    c.read(projectTasksProvider.notifier).assign('job1', 'projA');

    expect(c.read(projectTasksProvider), {'job1': 'projA'});
    // A fresh controller (next launch) sees the same link.
    expect(container().read(projectTasksProvider), {'job1': 'projA'});
  });

  test('untying a removed task drops it from the map and the file', () {
    final c = container();
    c.read(projectTasksProvider.notifier).assign('job1', 'projA');
    c.read(projectTasksProvider.notifier).assign('job2', 'projA');

    c.read(projectTasksProvider.notifier).unassign('job1');

    expect(c.read(projectTasksProvider), {'job2': 'projA'});
    expect(container().read(projectTasksProvider), {'job2': 'projA'});
  });

  test('untying a task that was never tied is a no-op, not a crash', () {
    final c = container();
    c.read(projectTasksProvider.notifier).assign('job1', 'projA');

    c.read(projectTasksProvider.notifier).unassign('ghost');

    expect(c.read(projectTasksProvider), {'job1': 'projA'});
  });

  test('projectJobIds gives only the tasks that belong to a project', () {
    final c = container();
    final notifier = c.read(projectTasksProvider.notifier);
    notifier.assign('job1', 'projA');
    notifier.assign('job2', 'projB');
    notifier.assign('job3', 'projA');

    expect(c.read(projectJobIdsProvider('projA')), {'job1', 'job3'});
    expect(c.read(projectJobIdsProvider('projB')), {'job2'});
    expect(c.read(projectJobIdsProvider('projC')), isEmpty);
  });

  test('a corrupt store reads as no links instead of throwing', () {
    file.writeAsStringSync('{ not json');
    expect(ProjectTasksStore(file: file).load(), isEmpty);
  });

  test('loading skips entries that are not string→string', () {
    file.writeAsStringSync('{"job1": "projA", "job2": 42, "job3": null}');
    expect(ProjectTasksStore(file: file).load(), {'job1': 'projA'});
  });
}
