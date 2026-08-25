import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/active_chat_agent.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_grid_support.dart';
import 'package:grid_app/features/chat/logic/chat_scope.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/projects/logic/project.dart';
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
///
/// [project] is the project the chat on screen sits in — null for a loose chat,
/// which is what most of these are about. Stubbed at [openChatProjectIdProvider]
/// so no test builds the chat sessions controller (and reads a real `~/.grid`).
///
/// [pinned] is the agent the chat on screen fixed when it started — null for a
/// chat that hasn't started one, which is what most of these are about. Stubbed
/// for the same reason the project is: it is read off the chat sessions
/// controller, and no test here may build one.
ProviderContainer _container({
  required String chosen,
  required bool hermes,
  required bool codex,
  bool claude = false,
  Set<AgentTool> blocked = const {},
  Project? project,
  String? pinned,
}) {
  final container = ProviderContainer(
    overrides: [
      chatPrefsProvider.overrideWith(
        () => _FixedPrefs(ChatPrefs(chatAgent: chosen)),
      ),
      openChatProjectIdProvider.overrideWithValue(project?.id),
      openChatAgentPinProvider.overrideWithValue(pinned),
      if (project != null)
        projectByIdProvider(project.id).overrideWith((ref) => project),
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

/// A project that has (or hasn't) picked its own assistant.
Project _project({String? agent}) =>
    Project(id: 'p1', name: 'grid-apis', path: '/repo/grid-apis', agent: agent);

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

  group('a chat inside a project', () {
    test("answers with the project's own assistant, not the app's", () {
      // The whole point of the per-project choice: the user set this repo to
      // Codex once, and it holds there whatever the app was last left on.
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        project: _project(agent: 'codex'),
      );
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
    });

    test("follows the app's choice while the project has picked nobody", () {
      final container = _container(
        chosen: 'codex',
        hermes: true,
        codex: true,
        project: _project(),
      );
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
    });

    test('a project pointed at an agent this build dropped falls back rather '
        'than leaving the chat unanswerable', () {
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        project: _project(agent: 'gone'),
      );
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
    });

    test("a project's pick this grid can't run is reported as the hand-over, "
        'the same as the app-wide one', () {
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        blocked: const {AgentTool.codex},
        project: _project(agent: 'codex'),
      );
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
      expect(container.read(blockedChatAgentProvider), AgentTool.codex);
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
      final container = _container(chosen: 'codex', hermes: true, codex: true);
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

  group('a chat that has started keeps the agent it started with', () {
    test("the chat's own agent outranks the picker's standing choice", () {
      // The picker was moved to Hermes — in a *new* chat, or in another chat
      // sharing the same scope. A session Codex is already holding must not be
      // handed to an agent that has never read a word of it.
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        pinned: 'codex',
      );
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
    });

    test('the next chat still starts on the standing choice', () {
      // The other half of the same rule: pinning one chat must not re-point the
      // setting, or the Agents screen and the picker would report a choice the
      // user never made.
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        pinned: 'codex',
      );
      expect(container.read(scopeChatAgentProvider), AgentTool.hermes);
    });

    test("a pinned agent this grid can't run still hands the chat over", () {
      // A pin is a preference, not a promise: an agent the grid cannot run
      // answers nothing, so the chat is borrowed by one that can — the same
      // fallback a project's pick gets, and the handover bar says so.
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        pinned: 'codex',
        blocked: {AgentTool.codex},
      );
      expect(container.read(activeChatAgentProvider), AgentTool.hermes);
      expect(container.read(blockedChatAgentProvider), AgentTool.codex);
    });

    test('a chat with no agent of its own follows the picker', () {
      // Every chat saved before sessions wrote their agent down. It keeps the
      // behaviour it had until its next message pins one.
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
    });
  });

  group('the sender follows the agent a turn was resolved for', () {
    /// The sender chat routing would use for whichever agent answers here.
    ChatSender senderFor(ProviderContainer container) => container.read(
      agentChatSenderProvider(container.read(activeChatAgentProvider)),
    );

    test('Codex active routes chats through the Codex sender', () {
      final container = _container(chosen: 'codex', hermes: true, codex: true);
      expect(
        senderFor(container),
        same(container.read(codexChatSenderProvider)),
      );
    });

    test('Hermes active routes chats through the Hermes sender', () {
      final container = _container(chosen: 'hermes', hermes: true, codex: true);
      expect(
        senderFor(container),
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
        senderFor(container),
        same(container.read(claudeChatSenderProvider)),
      );
    });

    test("a project's turn is sent by its own agent, not the open chat's", () {
      // A follow-up queued in one project goes out minutes later, by which time
      // the user may be reading another. It must still be answered by the agent
      // the project it was typed in runs.
      final container = _container(
        chosen: 'hermes',
        hermes: true,
        codex: true,
        project: _project(agent: 'codex'),
      );
      expect(container.read(activeChatAgentProvider), AgentTool.codex);
      expect(
        container.read(
          agentChatSenderProvider(
            container.read(chatAgentForProjectProvider(null)),
          ),
        ),
        same(container.read(hermesChatSenderProvider)),
      );
    });
  });
}
