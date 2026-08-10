import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/projects/logic/agent_workspace.dart';
import 'package:grid_app/shared/workspace/workspace_entries.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('grid_workspace_test');
  });
  tearDown(() => workspace.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [agentWorkspaceDirProvider.overrideWithValue(workspace)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('an untouched workspace lists nothing (and does not throw)', () async {
    final entries = await container().read(workspaceEntriesProvider.future);
    expect(entries, isEmpty);
  });

  test('lists folders first, then files, each alphabetical — the order Finder '
      'shows, so the screen and the folder agree', () async {
    await File('${workspace.path}/notes.md').writeAsString('hello');
    await File('${workspace.path}/aaa.txt').writeAsString('x');
    await Directory('${workspace.path}/docs').create();

    final entries = await container().read(workspaceEntriesProvider.future);

    expect(entries.map((e) => e.name).toList(), [
      'docs',
      'aaa.txt',
      'notes.md',
    ]);
    expect(entries.first.isDirectory, isTrue);
    expect(entries.last.sizeBytes, 5);
  });

  test("hides the OS's own dotfiles — they aren't the user's files", () async {
    await File('${workspace.path}/.DS_Store').writeAsString('junk');
    await File('${workspace.path}/report.pdf').writeAsString('x');

    final entries = await container().read(workspaceEntriesProvider.future);

    expect(entries.map((e) => e.name).toList(), ['report.pdf']);
  });

  group('workspaceSizeLabel', () {
    WorkspaceEntry entry({required bool isDirectory, required int size}) =>
        WorkspaceEntry(
          name: 'x',
          path: '/x',
          isDirectory: isDirectory,
          sizeBytes: size,
          modified: DateTime(2026),
        );

    test('scales bytes into a size a person reads', () {
      expect(workspaceSizeLabel(entry(isDirectory: false, size: 900)), '900 B');
      expect(
        workspaceSizeLabel(entry(isDirectory: false, size: 2048)),
        '2.0 KB',
      );
      expect(
        workspaceSizeLabel(entry(isDirectory: false, size: 5 * 1024 * 1024)),
        '5.0 MB',
      );
    });

    test('a folder says so instead of claiming 0 B', () {
      expect(workspaceSizeLabel(entry(isDirectory: true, size: 0)), 'Folder');
    });
  });
}
