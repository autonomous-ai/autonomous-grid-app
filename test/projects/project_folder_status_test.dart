import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/features/projects/logic/project_folder_status.dart';

/// The folder check moved off the widgets' `build()`: a blocking `existsSync()`
/// there held the UI thread for as long as a network share took to answer.
///
/// What these pin is what the app is allowed to *say* while it waits. Telling
/// someone the folder their chats live in has disappeared is the expensive
/// mistake here, so silence has to read as "still there".

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_project_folder_test');
    file = File('${tmp.path}/projects.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  /// A container holding a project per entry in [paths], whose folder check
  /// answers from [probe] — no filesystem, so the answers are deterministic.
  ProviderContainer container({
    required List<String> paths,
    required FolderProbe probe,
  }) {
    final c = ProviderContainer(
      overrides: [
        projectsStoreProvider.overrideWithValue(ProjectsStore(file: file)),
        folderProbeProvider.overrideWithValue(probe),
      ],
    );
    addTearDown(c.dispose);
    for (final path in paths) {
      c.read(projectsProvider.notifier).add(path);
    }
    // Something has to be listening: the check disposes itself when no screen
    // is watching it.
    c.listen(missingProjectFoldersProvider, (_, _) {});
    return c;
  }

  test('a folder that is gone is reported missing, and one that is there is '
      'left alone', () async {
    final c = container(
      paths: ['${tmp.path}/gone', '${tmp.path}/here'],
      probe: (path) async => path.endsWith('here'),
    );

    expect(await c.read(missingProjectFoldersProvider.future), {
      '${tmp.path}/gone',
    });
  });

  test('a folder nothing has answered for yet is not called missing — a share '
      'taking its time is not a folder that has disappeared', () async {
    final answer = Completer<bool>();
    addTearDown(() => answer.complete(true));
    final c = container(
      paths: ['${tmp.path}/slow'],
      probe: (_) => answer.future,
    );

    // No answer means no verdict, which the UI reads as present: the badge
    // arriving a frame late beats a badge that lies for a frame.
    expect(c.read(missingProjectFoldersProvider).value, isNull);
  });

  test('a folder whose check fails outright reads as present — the app waiting '
      'out a dead mount is not the user losing their work', () async {
    final c = container(
      paths: ['${tmp.path}/unreachable'],
      probe: (_) async =>
          throw const FileSystemException('the mount stopped answering'),
    );

    expect(await c.read(missingProjectFoldersProvider.future), isEmpty);
  });

  test('adding a project checks its folder too, rather than reporting on the '
      'list as it was', () async {
    final c = container(
      paths: ['${tmp.path}/here'],
      probe: (path) async => path.endsWith('here'),
    );
    expect(await c.read(missingProjectFoldersProvider.future), isEmpty);

    c.read(projectsProvider.notifier).add('${tmp.path}/gone');

    expect(await c.read(missingProjectFoldersProvider.future), {
      '${tmp.path}/gone',
    });
  });
}
