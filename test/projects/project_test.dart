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
}
