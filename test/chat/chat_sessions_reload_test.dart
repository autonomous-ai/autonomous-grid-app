import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';

/// The history is held in memory, and one thing outside this controller writes
/// to the chat folder: restoring a cloud backup. These cover what has to happen
/// afterwards for the user to actually see their chats — and a bug that made
/// the list go permanently empty instead.
void main() {
  late Directory dir;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('chat_reload');
    container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(ChatStore(directory: dir)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  void writeChat(String id, {String title = 'restored', String? updatedAt}) {
    File('${dir.path}/$id.json').writeAsStringSync('''
{"id":"$id","title":"$title","model":"auto","projectId":null,
 "titleLocked":false,"createdAt":"2026-08-11T09:45:00.000Z",
 "updatedAt":"${updatedAt ?? '2026-08-11T09:45:28.746Z'}",
 "messages":[{"role":"user","text":"hi"}]}
''');
  }

  Future<void> settled() async {
    container.read(chatSessionsProvider);
    await container.read(chatSessionsProvider.notifier).restored;
  }

  test('a chat written to the folder afterwards shows up on reload', () async {
    await settled();
    expect(container.read(chatSessionsProvider).conversations, isEmpty);

    writeChat('1786441404424597');
    await container.read(chatSessionsProvider.notifier).reloadFromDisk();

    expect(
      container.read(chatSessionsProvider).conversations.single.title,
      'restored',
    );
  });

  test('a reload does not drop chats that are only in memory', () async {
    // A chat started but never sent has no file yet; a restore must not make it
    // disappear from under the person typing in it.
    await settled();
    container.read(chatSessionsProvider.notifier).newChat();
    writeChat('1786441404424597');

    await container.read(chatSessionsProvider.notifier).reloadFromDisk();

    expect(container.read(chatSessionsProvider).conversations, hasLength(1));
    expect(container.read(chatSessionsProvider).activeId, isNull);
  });

  test('rebuilding the provider still reads the history', () async {
    // Regression: `_disposed` is set when a build is torn down, and Riverpod
    // reuses the same notifier for the next one. Left standing, `_restore`
    // read the folder and then dropped what it read — the history went empty
    // and stayed empty for the rest of the session, whatever was on disk.
    writeChat('1786441404424597');
    await settled();
    expect(container.read(chatSessionsProvider).conversations, hasLength(1));

    container.invalidate(chatSessionsProvider);
    await settled();

    expect(container.read(chatSessionsProvider).conversations, hasLength(1));
  });
}
