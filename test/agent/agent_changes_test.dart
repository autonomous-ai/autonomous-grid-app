import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_changes.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grid_agent_changes');
  });
  tearDown(() => dir.delete(recursive: true));

  AgentChangesController controller() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c.read(agentChangesProvider.notifier);
  }

  String path(String name) => '${dir.path}/$name';

  test('records an edit at an absolute path', () {
    final c = controller();
    c.record(path: path('a.txt'), before: 'old', after: 'new');
    expect(c.state, hasLength(1));
    expect(c.state.single.before, 'old');
  });

  test('ignores a relative path — undo could not find the right file', () {
    final c = controller();
    c.record(path: 'notes.txt', before: 'x', after: 'y');
    expect(c.state, isEmpty);
  });

  test('expands a ~ path so a file the agent wrote to ~/Downloads is recorded '
      'and undoable, not silently dropped', () {
    final home = Platform.environment['HOME']!;
    final c = controller();

    c.record(
      path: '~/Downloads/hello_world_all_languages.txt',
      before: null,
      after: 'hi',
    );

    expect(c.state, hasLength(1));
    expect(
      c.state.single.path,
      '$home/Downloads/hello_world_all_languages.txt',
    );
  });

  test(
    'expandHome turns a leading ~ into the home dir, leaves the rest alone',
    () {
      expect(
        expandHome('~/Downloads/a.txt', '/Users/me'),
        '/Users/me/Downloads/a.txt',
      );
      expect(expandHome('~', '/Users/me'), '/Users/me');
      expect(expandHome('/etc/hosts', '/Users/me'), '/etc/hosts');
      // A bare `~name` is not a home reference — left untouched.
      expect(expandHome('~notes', '/Users/me'), '~notes');
    },
  );

  test('a second edit to a file keeps the original before, updates after', () {
    final c = controller();
    c.record(path: path('a.txt'), before: 'v1', after: 'v2');
    c.record(path: path('a.txt'), before: 'v2', after: 'v3');
    expect(c.state, hasLength(1));
    expect(c.state.single.before, 'v1');
    expect(c.state.single.after, 'v3');
  });

  test('revert restores the original contents and drops the entry', () async {
    final file = File(path('a.txt'))..writeAsStringSync('changed');
    final c = controller();
    c.record(path: file.path, before: 'original', after: 'changed');

    final error = await c.revert(c.state.single);

    expect(error, isNull);
    expect(file.readAsStringSync(), 'original');
    expect(c.state, isEmpty);
  });

  test('reverting a created file deletes it', () async {
    final file = File(path('made.txt'))..writeAsStringSync('by agent');
    final c = controller();
    c.record(path: file.path, before: null, after: 'by agent');

    await c.revert(c.state.single);

    expect(file.existsSync(), isFalse);
  });

  test('revertAll puts every file back and clears the list', () async {
    final a = File(path('a.txt'))..writeAsStringSync('A2');
    final b = File(path('b.txt'))..writeAsStringSync('B2');
    final c = controller();
    c.record(path: a.path, before: 'A1', after: 'A2');
    c.record(path: b.path, before: 'B1', after: 'B2');

    final error = await c.revertAll();

    expect(error, isNull);
    expect(a.readAsStringSync(), 'A1');
    expect(b.readAsStringSync(), 'B1');
    expect(c.state, isEmpty);
  });

  test('clear forgets changes without touching the files', () {
    final file = File(path('a.txt'))..writeAsStringSync('changed');
    final c = controller();
    c.record(path: file.path, before: 'original', after: 'changed');

    c.clear();

    expect(c.state, isEmpty);
    expect(file.readAsStringSync(), 'changed');
  });
}
