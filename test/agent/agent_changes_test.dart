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

  /// A container with one chat open and its agent turn running, which is the
  /// state every recorded change is made in.
  ProviderContainer open(String chatId) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(agentChangesScopeProvider.notifier).show(chatId);
    c.read(agentChangesProvider.notifier).attributeTo(chatId);
    return c;
  }

  List<AgentChange> changesIn(ProviderContainer c, String chatId) =>
      c.read(agentChangesProvider)[chatId] ?? const [];

  String path(String name) => '${dir.path}/$name';

  test('records an edit at an absolute path under the chat that made it', () {
    final c = open('chat-1');
    c
        .read(agentChangesProvider.notifier)
        .record(path: path('a.txt'), before: 'old', after: 'new');
    expect(changesIn(c, 'chat-1'), hasLength(1));
    expect(changesIn(c, 'chat-1').single.before, 'old');
  });

  test('ignores a relative path — undo could not find the right file', () {
    final c = open('chat-1');
    c
        .read(agentChangesProvider.notifier)
        .record(path: 'notes.txt', before: 'x', after: 'y');
    expect(changesIn(c, 'chat-1'), isEmpty);
  });

  test('expands a ~ path so a file the agent wrote to ~/Downloads is recorded '
      'and undoable, not silently dropped', () {
    final home = Platform.environment['HOME']!;
    final c = open('chat-1');

    c
        .read(agentChangesProvider.notifier)
        .record(
          path: '~/Downloads/hello_world_all_languages.txt',
          before: null,
          after: 'hi',
        );

    expect(
      changesIn(c, 'chat-1').single.path,
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
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: path('a.txt'), before: 'v1', after: 'v2');
    changes.record(path: path('a.txt'), before: 'v2', after: 'v3');
    expect(changesIn(c, 'chat-1'), hasLength(1));
    expect(changesIn(c, 'chat-1').single.before, 'v1');
    expect(changesIn(c, 'chat-1').single.after, 'v3');
  });

  test('a turn that finishes after the user moved on files its edit under the '
      'chat that asked for it, not the one on screen', () {
    final c = open('chat-1');
    // The user opens another conversation while the agent is still working.
    c.read(agentChangesScopeProvider.notifier).show('chat-2');

    c
        .read(agentChangesProvider.notifier)
        .record(path: path('a.txt'), before: 'old', after: 'new');

    expect(changesIn(c, 'chat-1'), hasLength(1));
    expect(changesIn(c, 'chat-2'), isEmpty);
    // The chat on screen offers nothing to undo; going back to chat-1 does.
    expect(c.read(visibleAgentChangesProvider), isEmpty);
    c.read(agentChangesScopeProvider.notifier).show('chat-1');
    expect(c.read(visibleAgentChangesProvider), hasLength(1));
  });

  test('revert restores the original contents and drops the entry', () async {
    final file = File(path('a.txt'))..writeAsStringSync('changed');
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: file.path, before: 'original', after: 'changed');

    final error = await changes.revert(changesIn(c, 'chat-1').single);

    expect(error, isNull);
    expect(file.readAsStringSync(), 'original');
    expect(changesIn(c, 'chat-1'), isEmpty);
  });

  test('reverting a created file deletes it', () async {
    final file = File(path('made.txt'))..writeAsStringSync('by agent');
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: file.path, before: null, after: 'by agent');

    await changes.revert(changesIn(c, 'chat-1').single);

    expect(file.existsSync(), isFalse);
  });

  test('revertAll puts back every file of the open chat and leaves another '
      "conversation's changes alone", () async {
    final a = File(path('a.txt'))..writeAsStringSync('A2');
    final b = File(path('b.txt'))..writeAsStringSync('B2');
    final other = File(path('other.txt'))..writeAsStringSync('O2');
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: a.path, before: 'A1', after: 'A2');
    changes.record(path: b.path, before: 'B1', after: 'B2');
    changes.attributeTo('chat-2');
    changes.record(path: other.path, before: 'O1', after: 'O2');

    final error = await changes.revertAll();

    expect(error, isNull);
    expect(a.readAsStringSync(), 'A1');
    expect(b.readAsStringSync(), 'B1');
    expect(changesIn(c, 'chat-1'), isEmpty);
    // Undo all means "this chat", so the other conversation still has its own.
    expect(other.readAsStringSync(), 'O2');
    expect(changesIn(c, 'chat-2'), hasLength(1));
  });

  test("forget drops a deleted chat's changes without touching the files, and "
      'stops recording the turn that was still running for it', () {
    final file = File(path('a.txt'))..writeAsStringSync('changed');
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: file.path, before: 'original', after: 'changed');

    changes.forget('chat-1');
    changes.record(path: path('b.txt'), before: null, after: 'late');

    expect(c.read(agentChangesProvider), isEmpty);
    expect(file.readAsStringSync(), 'changed');
  });

  test('undoing every change leaves the running turn still filed under its '
      'chat, so what the agent writes next is undoable too', () async {
    final a = File(path('a.txt'))..writeAsStringSync('A2');
    final c = open('chat-1');
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: a.path, before: 'A1', after: 'A2');

    await changes.revertAll();
    changes.record(path: path('b.txt'), before: null, after: 'next');

    expect(changesIn(c, 'chat-1'), hasLength(1));
  });

  test('a change recorded before any chat claimed the turn is not filed '
      'anywhere — it would be undoable from nowhere', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    c
        .read(agentChangesProvider.notifier)
        .record(path: path('a.txt'), before: 'old', after: 'new');

    expect(c.read(agentChangesProvider), isEmpty);
  });
}
