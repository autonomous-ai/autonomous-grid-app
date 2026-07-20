import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/codex_chat_sender.dart';
import 'package:grid_app/features/agent/logic/codex_tool.dart';
import 'package:grid_app/features/agent/logic/hermes_chat_sender.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/active_chat_agent.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

/// A prefs controller pinned to a fixed value, so a test controls the remembered
/// choice without touching a real `chat_prefs.json`.
class _FixedPrefs extends ChatPrefsController {
  _FixedPrefs(this._prefs);

  final ChatPrefs _prefs;

  @override
  ChatPrefs build() => _prefs;
}

ProviderContainer _container({
  required String chosen,
  required bool hermes,
  required bool codex,
}) {
  final container = ProviderContainer(
    overrides: [
      chatPrefsProvider.overrideWith(
        () => _FixedPrefs(ChatPrefs(chatAgent: chosen)),
      ),
      hermesInstalledProvider.overrideWithValue(hermes),
      codexInstalledProvider.overrideWithValue(codex),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('which agent answers chats', () {
    test('the remembered choice wins when it is installed', () {
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
    });

    test('a choice for a since-removed agent falls back to one installed', () {
      // The user picked Codex, then uninstalled it — chat must not stay pointed
      // at an agent that isn't there.
      final container = _container(chosen: 'codex', hermes: true, codex: false);
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
    });

    test('the default choice is Hermes when it is installed', () {
      final container = _container(chosen: 'hermes', hermes: true, codex: true);
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
    });

    test('with nothing installed it reports the catalog default', () {
      final container = _container(chosen: 'codex', hermes: false, codex: false);
      expect(container.read(activeChatAgentProvider), kChatAgent);
    });
  });

  group('the sender follows the active agent', () {
    test('Codex active routes chats through the Codex sender', () {
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(
        container.read(chatAgentSenderProvider),
        same(container.read(codexChatSenderProvider)),
      );
    });

    test('Hermes active routes chats through the Hermes sender', () {
      final container = _container(chosen: 'hermes', hermes: true, codex: true);
      expect(
        container.read(chatAgentSenderProvider),
        same(container.read(hermesChatSenderProvider)),
      );
    });
  });
}
