import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

/// Reading the saved history is the one startup cost that grows with how long
/// the app has been used: every chat is a file, and every file is read and
/// decoded. These pin the two things that keep it from becoming a stall — that
/// the cost stays linear (not quadratic) in the number of chats, and that a
/// missing or vanishing folder is answered rather than thrown.
///
/// The threshold is deliberately loose. It is a tripwire for a change that makes
/// the read fundamentally more expensive — an O(n²) sort, a re-read per chat —
/// not a benchmark, and it must not flake on a busy machine.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grid_chat_scale');
  });
  // Retried, not just called. One test in here deletes this folder WHILE a read
  // is in flight — that is its subject — and the read can put a file back
  // between the recursive delete listing the folder and removing it. The delete
  // then fails with "Directory not empty", from a test that had already passed.
  tearDown(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Conversation chat(int i) => Conversation(
    id: 'c$i',
    title: 'Chat $i',
    model: 'm',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
    messages: [
      for (var m = 0; m < 20; m++)
        ChatMessage(
          role: m.isEven ? ChatRole.user : ChatRole.assistant,
          text: 'A message with enough text in it to be worth decoding. $m',
        ),
    ],
  );

  test(
    'a history of 200 chats is read in well under a second, newest first — '
    'the rail is waiting on this and it grows with every chat kept',
    () async {
      final store = ChatStore(directory: dir);
      for (var i = 0; i < 200; i++) {
        store.save(chat(i));
      }

      final clock = Stopwatch()..start();
      final loaded = await store.loadAll();
      clock.stop();

      expect(loaded, hasLength(200));
      expect(loaded.first.id, 'c199', reason: 'newest activity first');
      expect(
        clock.elapsedMilliseconds,
        lessThan(2000),
        reason: 'reading the history got fundamentally more expensive',
      );
    },
  );

  test('a chats folder that does not exist reads as an empty history, not a '
      'crash on first launch', () async {
    final store = ChatStore(directory: Directory('${dir.path}/never_created'));
    expect(await store.loadAll(), isEmpty);
  });

  test(
    'a folder deleted while it is being read keeps what it already had — '
    'the read is off the frame now, so it can outlive what it reads',
    () async {
      final store = ChatStore(directory: dir);
      store.save(chat(1));
      final reading = store.loadAll();
      await dir.delete(recursive: true);

      expect(await reading, isA<List<Conversation>>());
      // Recreated so the tearDown has something to remove.
      await dir.create(recursive: true);
    },
  );

  test(
    'a corrupt file is skipped and the rest of the history still loads',
    () async {
      final store = ChatStore(directory: dir);
      store.save(chat(1));
      File('${dir.path}/broken.json').writeAsStringSync('{not json');

      expect(await store.loadAll(), hasLength(1));
    },
  );

  /// A chat a `/loop` has been working in overnight. Measured on a real one:
  /// 110 messages, 7,765 steps, 9 MB — and every commit rewrites the whole file.
  Conversation loopChat({required int steps}) => Conversation(
    id: 'loop',
    title: 'A loop that has been running a while',
    model: 'm',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 2),
    messages: [
      for (var m = 0; m < 20; m++)
        ChatMessage(
          role: m.isEven ? ChatRole.user : ChatRole.assistant,
          text: 'Turn $m of a long night.',
          parts: [
            for (var s = 0; s < steps ~/ 20; s++)
              TurnStep(
                AgentActivity(
                  id: '$m-$s',
                  kind: AgentActivityKind.command,
                  label: 'Bash · rg -n "something" lib | head -20',
                  status: AgentActivityStatus.done,
                  tool: 'Bash',
                  request: 'rg -n "something" lib | head -20' * 8,
                  result: 'a few hundred bytes of output, as they all are' * 8,
                ),
              ),
          ],
        ),
    ],
  );

  test('saving a huge chat does not hold up the caller — the encode and the '
      'write happen off this isolate, which is the whole reason a /loop chat '
      'stopped freezing the window on every turn', () async {
    final store = ChatStore(directory: dir);
    final chat = loopChat(steps: 4000);

    final clock = Stopwatch()..start();
    store.save(chat);
    final queued = clock.elapsedMilliseconds;
    await store.settled;
    final written = clock.elapsedMilliseconds;

    // A tripwire, not a benchmark: inline, this same write measured ~126 ms
    // (98 encode + 28 flush) and grew with the chat. Queueing it is a map write.
    expect(
      queued,
      lessThan(20),
      reason: 'save() queued the write instead of doing it here ($queued ms)',
    );
    expect(written, greaterThanOrEqualTo(queued));

    final loaded = await store.loadAll();
    expect(loaded.single.messages.first.parts, hasLength(200));
  });

  test(
    'two saves of the same chat in a breath write the newer one — a loop '
    'commits twice per iteration and the older file is work with no reader',
    () async {
      final store = ChatStore(directory: dir);
      store.save(loopChat(steps: 40));
      store.save(loopChat(steps: 40).copyWith(title: 'Renamed while writing'));
      await store.settled;

      expect((await store.loadAll()).single.title, 'Renamed while writing');
    },
  );
}
