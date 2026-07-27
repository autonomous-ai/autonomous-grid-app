import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
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
      store.save(const ChatPrefs(networkId: 'grid-1', model: 'qwen'));

      final loaded = ChatPrefsStore(file: file).load();
      expect(loaded.networkId, 'grid-1');
      expect(loaded.model, 'qwen');
    });

    test('reads empty from a corrupt file instead of throwing', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{ not json');
      expect(ChatPrefsStore(file: file).load(), ChatPrefs.empty);
    });

    test('what the agent may do survives a restart', () {
      ChatPrefsStore(
        file: file,
      ).save(const ChatPrefs(approval: AgentApprovalMode.full));

      expect(
        ChatPrefsStore(file: file).load().approval,
        AgentApprovalMode.full,
      );
    });

    test('a brand-new install lets the agent work without asking (Full)', () {
      expect(ChatPrefs.empty.approval, AgentApprovalMode.full);
    });

    test('a hand-edited or corrupt approval reads as "ask" — a broken file must '
        'never hand the agent more than the user granted', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"approval": "sudo-everything"}');

      expect(ChatPrefsStore(file: file).load().approval, AgentApprovalMode.ask);
    });

    test('the chosen theme survives a restart', () {
      ChatPrefsStore(
        file: file,
      ).save(const ChatPrefs(themeMode: ThemeMode.dark));

      expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.dark);
    });

    test(
      'an unset or hand-edited theme reads as Light — the shipped default',
      () {
        expect(ChatPrefs.empty.themeMode, ThemeMode.light);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{"themeMode": "solarized"}');

        expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.light);
      },
    );
  });

  group('chatPrefsProvider', () {
    test('each setter persists and merges without dropping the others', () {
      final c = container();
      final notifier = c.read(chatPrefsProvider.notifier);

      notifier.setNetwork('grid-1');
      notifier.setModel('qwen');

      // Every field survived the successive writes.
      expect(
        c.read(chatPrefsProvider),
        const ChatPrefs(networkId: 'grid-1', model: 'qwen'),
      );
      // And it's on disk, not just in memory.
      expect(ChatPrefsStore(file: file).load().model, 'qwen');
    });

    test('a fresh controller restores what a prior session saved', () {
      ChatPrefsStore(file: file).save(const ChatPrefs(networkId: 'grid-9'));
      expect(container().read(chatPrefsProvider).networkId, 'grid-9');
    });

    test('themeModeProvider reflects the setter and defaults to Light', () {
      final c = container();
      expect(c.read(themeModeProvider), ThemeMode.light);

      c.read(chatPrefsProvider.notifier).setThemeMode(ThemeMode.system);
      expect(c.read(themeModeProvider), ThemeMode.system);
      // Persisted, not just in memory.
      expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.system);
    });

    test('picking the chat agent persists — the setter is not swallowed by '
        'equality', () {
      // The default is Hermes; only a real change should be written. This guards
      // the trap that sank "Use for chat": if `chatAgent` is left out of
      // `operator ==`, the update short-circuits and nothing changes.
      final c = container();
      expect(c.read(chatPrefsProvider).chatAgent, ChatPrefs.defaultChatAgent);

      c.read(chatPrefsProvider.notifier).setChatAgent('codex');
      expect(c.read(chatPrefsProvider).chatAgent, 'codex');
      // On disk, not just in memory.
      expect(ChatPrefsStore(file: file).load().chatAgent, 'codex');
    });
  });
}
