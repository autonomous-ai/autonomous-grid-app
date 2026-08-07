import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/projects/logic/agent_workspace.dart';

void main() {
  test('a missing folder lists nothing instead of throwing', () async {
    final gone = Directory('${Directory.systemTemp.path}/grid_no_such_dir_xyz');
    expect(await readWorkspaceEntries(gone), isEmpty);
  });

  test(
    'lists a folder\'s files, folders first, skipping dotfiles by default',
    () async {
      final dir = await Directory.systemTemp.createTemp('grid_workdir_entries');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/notes.md').writeAsString('x');
      await File('${dir.path}/.DS_Store').writeAsString('junk');
      await Directory('${dir.path}/docs').create();

      final entries = await readWorkspaceEntries(dir);

      expect(entries.map((e) => e.name), ['docs', 'notes.md']);
      expect(entries.first.isDirectory, isTrue);
    },
  );

  // A file browser that dropped these would be lying about what is in the
  // project: `.github`, `.env` and `.gitignore` are the user's files, not the
  // OS's leftovers, and they sort in with everything else rather than into a
  // group of their own.
  test('shows dotfiles when asked, still folders first', () async {
    final dir = await Directory.systemTemp.createTemp('grid_workdir_hidden');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/notes.md').writeAsString('x');
    await File('${dir.path}/.gitignore').writeAsString('build/');
    await Directory('${dir.path}/docs').create();
    await Directory('${dir.path}/.github').create();

    final entries = await readWorkspaceEntries(dir, includeHidden: true);

    expect(entries.map((e) => e.name), [
      '.github',
      'docs',
      '.gitignore',
      'notes.md',
    ]);
  });
}
