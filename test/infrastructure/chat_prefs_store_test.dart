import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_chat_prefs_test');
    file = File('${tmp.path}/app/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('ChatPrefsStore', () {
    test('reads empty when the file is missing', () {
      expect(ChatPrefsStore(file: file).load(), ChatPrefs.empty);
    });

    test('round-trips a saved selection through disk', () {
      final store = ChatPrefsStore(file: file);
      store.save(
        const ChatPrefs(networkId: 'grid-1', model: 'qwen', agent: 'hermes'),
      );

      final loaded = ChatPrefsStore(file: file).load();
      expect(loaded.networkId, 'grid-1');
      expect(loaded.model, 'qwen');
      expect(loaded.agent, 'hermes');
    });

    test('reads empty from a corrupt file instead of throwing', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{ not json');
      expect(ChatPrefsStore(file: file).load(), ChatPrefs.empty);
    });
  });

  group('chatPrefsProvider', () {
    test('each setter persists and merges without dropping the others', () {
      final c = container();
      final notifier = c.read(chatPrefsProvider.notifier);

      notifier.setNetwork('grid-1');
      notifier.setModel('qwen');
      notifier.setAgent('codex');

      // Every field survived the successive writes.
      expect(
        c.read(chatPrefsProvider),
        const ChatPrefs(networkId: 'grid-1', model: 'qwen', agent: 'codex'),
      );
      // And it's on disk, not just in memory.
      expect(ChatPrefsStore(file: file).load().model, 'qwen');
    });

    test('a fresh controller restores what a prior session saved', () {
      ChatPrefsStore(file: file).save(const ChatPrefs(networkId: 'grid-9'));
      expect(container().read(chatPrefsProvider).networkId, 'grid-9');
    });
  });
}
