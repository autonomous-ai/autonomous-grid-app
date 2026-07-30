import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/claude_chat_sender.dart';
import 'package:grid_app/features/agent/logic/claude_tool.dart';
import 'package:grid_app/features/agent/logic/codex_chat_sender.dart';
import 'package:grid_app/features/agent/logic/codex_tool.dart';
import 'package:grid_app/features/agent/logic/hermes_chat_sender.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/active_chat_agent.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_grid_support.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

/// A prefs controller pinned to a fixed value, so a test controls the remembered
/// choice without touching a real `chat_prefs.json`.
class _FixedPrefs extends ChatPrefsController {
  _FixedPrefs(this._prefs);

  final ChatPrefs _prefs;

  @override
  ChatPrefs build() => _prefs;
}

/// [blocked] names the agents the open grid can't run. Which dialect decides
/// that is `agent_grid_support_test`'s subject; here it is stubbed outright, so
/// these tests are about *picking* an agent and no test reaches for a real grid.
ProviderContainer _container({
  required String chosen,
  required bool hermes,
  required bool codex,
  bool claude = false,
  Set<AgentTool> blocked = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      chatPrefsProvider.overrideWith(
        () => _FixedPrefs(ChatPrefs(chatAgent: chosen)),
      ),
      hermesInstalledProvider.overrideWithValue(hermes),
      codexInstalledProvider.overrideWithValue(codex),
      claudeInstalledProvider.overrideWithValue(claude),
      agentRunsOnGridProvider.overrideWith(
        (ref, tool) => !blocked.contains(tool),
      ),
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
      final container = _container(
        chosen: 'codex',
        hermes: false,
        codex: false,
      );
      expect(container.read(activeChatAgentProvider), kChatAgent);
    });
  });

  group('a grid that cannot run the chosen agent', () {
    test('hands the chat to one it can run', () {
      // The grid serves nothing Codex can talk to. Letting Codex keep the chat
      // would fail on the first message with a 404 the user can't act on.
      final container = _container(
        chosen: 'codex',
        hermes: true,
        codex: true,
        blocked: const {AgentTool.codex},
      );
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
      expect(container.read(blockedChatAgentProvider), AgentTool.codex);
    });

    test('gives the chat back on a grid that can run it', () {
      // The hand-over is resolved per grid, never written to prefs: the user
      // picked Codex once and gets it back the moment a grid can serve it.
      final container = _container(
        chosen: 'codex',
        hermes: true,
        codex: true,
      );
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
      expect(container.read(blockedChatAgentProvider), isNull);
    });

    test('reports nothing while the grid has not said either way', () {
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
      expect(container.read(blockedChatAgentProvider), isNull);
    });

    test('an uninstalled pick is not reported as a grid problem', () {
      // Codex isn't there to run — that's an install to do, and the Agents
      // screen already says so. Blaming the grid would send the user hunting
      // for a different one.
      final container = _container(
        chosen: 'codex',
        hermes: true,
        codex: false,
        blocked: const {AgentTool.codex},
      );
      expect(container.read(blockedChatAgentProvider), isNull);
    });
  });

  group('the agent a failed turn can be handed to', () {
    test('is the other installed agent this grid can run', () {
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(container.read(alternativeChatAgentProvider), AgentTool.hermes);
    });

    test('is nothing when no other agent could do better', () {
      // Nothing to offer — the button stands down rather than promising a swap
      // that would change nothing.
      final container = _container(chosen: 'codex', hermes: false, codex: true);
      expect(container.read(alternativeChatAgentProvider), isNull);
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

    test('Claude Code active routes chats through its own sender', () {
      final container = _container(
        chosen: 'claude',
        hermes: true,
        codex: true,
        claude: true,
      );
      expect(container.read(activeChatAgentProvider), AgentTool.claude);
      expect(
        container.read(chatAgentSenderProvider),
        same(container.read(claudeChatSenderProvider)),
      );
    });
  });
}
