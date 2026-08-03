import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';

/// A store backed by a temp dir, so nothing here touches a real `~/.grid`.
///
/// Waits for the saved chats to be read back in: the controller reads them off
/// the first frame now, so a seeded dir isn't in its state the instant the
/// container is built.
Future<({ProviderContainer container, Directory dir})> _harness(
  List<Conversation> seed,
) async {
  final dir = Directory.systemTemp.createTempSync('archive_test');
  final store = ChatStore(directory: dir);
  for (final c in seed) {
    store.save(c);
  }
  final container = ProviderContainer(
    overrides: [chatStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  addTearDown(() => dir.deleteSync(recursive: true));
  await container.read(chatSessionsProvider.notifier).restored;
  return (container: container, dir: dir);
}

Conversation _chat({
  required String id,
  String title = 'Chat',
  DateTime? archivedAt,
  DateTime? updatedAt,
  String? projectId,
}) => Conversation(
  id: id,
  title: title,
  model: 'm',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt ?? DateTime(2026, 1, 1),
  archivedAt: archivedAt,
  projectId: projectId,
  messages: const [ChatMessage(role: ChatRole.user, text: 'hello')],
);

void main() {
  group('archiving', () {
    test(
      'hides the chat from `live` while keeping it in `conversations`',
      () async {
        final h = await _harness([_chat(id: 'a'), _chat(id: 'b')]);
        final controller = h.container.read(chatSessionsProvider.notifier);

        controller.archiveConversation('a');

        final state = h.container.read(chatSessionsProvider);
        expect(state.live.map((c) => c.id), ['b']);
        expect(state.archived.map((c) => c.id), ['a']);
        expect(state.conversations.length, 2, reason: 'nothing is deleted');
      },
    );

    test('keeps every message — archiving is hiding, not deleting', () async {
      final h = await _harness([_chat(id: 'a')]);
      h.container.read(chatSessionsProvider.notifier).archiveConversation('a');

      final archived = h.container.read(chatSessionsProvider).archived.single;
      expect(archived.messages.single.text, 'hello');
    });

    test('survives a reload — the flag is on disk, not in memory', () async {
      final h = await _harness([_chat(id: 'a')]);
      h.container.read(chatSessionsProvider.notifier).archiveConversation('a');

      // A fresh container over the same directory is what a relaunch looks like.
      final store = ChatStore(directory: h.dir);
      final reloaded = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(reloaded.dispose);
      await reloaded.read(chatSessionsProvider.notifier).restored;

      expect(reloaded.read(chatSessionsProvider).archived.map((c) => c.id), [
        'a',
      ]);
    });

    test('moves off the chat when the open one is archived', () async {
      final h = await _harness([
        _chat(id: 'a', updatedAt: DateTime(2026, 2, 1)),
        _chat(id: 'b', updatedAt: DateTime(2026, 1, 1)),
      ]);
      final controller = h.container.read(chatSessionsProvider.notifier);
      controller.select('a');

      controller.archiveConversation('a');

      // Falls back to a live chat rather than leaving the user staring at a
      // transcript the sidebar no longer lists.
      expect(h.container.read(chatSessionsProvider).activeId, 'b');
    });

    test('archiving the last chat leaves a fresh compose', () async {
      final h = await _harness([_chat(id: 'only')]);
      final controller = h.container.read(chatSessionsProvider.notifier);
      controller.archiveConversation('only');

      expect(h.container.read(chatSessionsProvider).activeId, isNull);
    });

    test(
      'leaves the open chat alone when a different one is archived',
      () async {
        final h = await _harness([_chat(id: 'a'), _chat(id: 'b')]);
        final controller = h.container.read(chatSessionsProvider.notifier);
        controller.select('b');

        controller.archiveConversation('a');

        expect(h.container.read(chatSessionsProvider).activeId, 'b');
      },
    );
  });

  group('unarchiving', () {
    test('puts the chat back without touching updatedAt', () async {
      final talkedIn = DateTime(2026, 3, 15);
      final h = await _harness([
        _chat(id: 'a', updatedAt: talkedIn, archivedAt: DateTime(2026, 6, 1)),
      ]);
      final controller = h.container.read(chatSessionsProvider.notifier);

      controller.unarchiveConversation('a');

      final restored = h.container.read(chatSessionsProvider).live.single;
      expect(restored.isArchived, isFalse);
      // Order in the sidebar is by updatedAt, so bumping it here would jump an
      // old chat to the top just for being restored.
      expect(restored.updatedAt, talkedIn);
    });

    test('clears the flag on disk too', () async {
      final h = await _harness([
        _chat(id: 'a', archivedAt: DateTime(2026, 6, 1)),
      ]);
      h.container
          .read(chatSessionsProvider.notifier)
          .unarchiveConversation('a');

      final reloaded = await ChatStore(directory: h.dir).loadAll();
      expect(reloaded.single.isArchived, isFalse);
    });
  });

  group('launch', () {
    test('opens a live chat, never an archived one', () async {
      // The archived chat is the newest, so a naive "first" would open it.
      final h = await _harness([
        _chat(
          id: 'archived',
          updatedAt: DateTime(2026, 6, 1),
          archivedAt: DateTime(2026, 6, 2),
        ),
        _chat(id: 'live', updatedAt: DateTime(2026, 1, 1)),
      ]);

      expect(h.container.read(chatSessionsProvider).activeId, 'live');
    });

    test('opens a compose when every saved chat is archived', () async {
      final h = await _harness([
        _chat(id: 'a', archivedAt: DateTime(2026, 6, 1)),
      ]);
      expect(h.container.read(chatSessionsProvider).activeId, isNull);
    });
  });

  group('deleteArchivedConversations', () {
    test('deletes every archived chat and spares the live ones', () async {
      final h = await _harness([
        _chat(id: 'x', archivedAt: DateTime(2026, 6, 1)),
        _chat(id: 'y', archivedAt: DateTime(2026, 6, 2)),
        _chat(id: 'keep'),
      ]);

      h.container
          .read(chatSessionsProvider.notifier)
          .deleteArchivedConversations();

      final state = h.container.read(chatSessionsProvider);
      expect(state.conversations.map((c) => c.id), ['keep']);
      // And gone from disk, not just from memory.
      expect((await ChatStore(directory: h.dir).loadAll()).map((c) => c.id), [
        'keep',
      ]);
    });

    test('scopes to the given ids for "delete all in project"', () async {
      final h = await _harness([
        _chat(id: 'web1', projectId: 'web', archivedAt: DateTime(2026, 6, 1)),
        _chat(id: 'api1', projectId: 'api', archivedAt: DateTime(2026, 6, 2)),
      ]);

      h.container
          .read(chatSessionsProvider.notifier)
          .deleteArchivedConversations(ids: {'web1'});

      expect(h.container.read(chatSessionsProvider).archived.map((c) => c.id), [
        'api1',
      ]);
    });

    test('cannot delete a live chat even if its id is passed', () async {
      // The guard that keeps "Delete all" from ever reaching working history.
      final h = await _harness([_chat(id: 'live')]);

      h.container
          .read(chatSessionsProvider.notifier)
          .deleteArchivedConversations(ids: {'live'});

      expect(h.container.read(chatSessionsProvider).live.map((c) => c.id), [
        'live',
      ]);
    });
  });

  group('conversation json', () {
    test('round-trips archivedAt', () {
      final at = DateTime(2026, 6, 1, 9, 30);
      final restored = Conversation.fromJson(
        _chat(id: 'a', archivedAt: at).toJson(),
      );
      expect(restored.archivedAt, at);
    });

    test('a chat saved before this field existed reads as live', () {
      // The migration case: no `archivedAt` key at all must mean live, or the
      // sidebar empties on first launch after the update.
      final json = _chat(id: 'a').toJson();
      expect(json.containsKey('archivedAt'), isFalse);
      expect(Conversation.fromJson(json).isArchived, isFalse);
    });

    test('an unparseable archivedAt reads as live rather than epoch', () {
      final json = _chat(id: 'a').toJson()..['archivedAt'] = 'not a date';
      expect(Conversation.fromJson(json).isArchived, isFalse);
    });
  });
}
