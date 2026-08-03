import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

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
  tearDown(() => dir.delete(recursive: true));

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
}
