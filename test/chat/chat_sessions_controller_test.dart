import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_resume_point.dart';
import 'package:grid_app/features/chat/logic/chat_approval.dart';
import 'package:grid_app/features/chat/logic/chat_goal.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/agents/logic/agent_session_title.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/pi_tool.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/auto_agent.dart';
import 'package:grid_app/features/chat/logic/chat_scope.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/infrastructure/api/chat_transport.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/media_outputs.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'net',
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/g1',
  accessToken: 'tok',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A [ChatSender] that replays canned updates and records what it was asked to
/// send — no live relay involved.
class _FakeSender implements ChatSender {
  _FakeSender(this.updates);
  final List<ChatSendUpdate> updates;
  List<ChatMessage>? history;
  String? model;
  PlaygroundModality? modality;
  List<MediaAttachment>? attachments;
  String? workdir;

  /// Whether each send was a Plan-mode planning turn, in call order.
  final planFirsts = <bool>[];

  /// The permission level each send was made under, in call order.
  final approvals = <AgentApprovalMode?>[];

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    this.history = history;
    this.model = model;
    this.modality = modality;
    this.attachments = attachments;
    this.workdir = workdir;
    planFirsts.add(planFirst);
    approvals.add(approval);
    return Stream.fromIterable(updates);
  }
}

/// A sender whose turns differ: one canned reply per call, in order, with the
/// last repeating once the script runs out.
///
/// [_FakeSender] replays the same updates for every turn, which can't express
/// "it ran out of room, then carried on and finished" — the sequence the carry-on
/// bar exists for.
class _ScriptedSender implements ChatSender {
  _ScriptedSender(this.turns);

  final List<List<ChatSendUpdate>> turns;

  /// How many turns were actually asked for.
  int calls = 0;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    final turn = turns[calls.clamp(0, turns.length - 1)];
    calls++;
    return Stream.fromIterable(turn);
  }
}

/// A reply that streams and then just keeps going — what Stop exists for. The
/// test drives it chunk by chunk, and [cancelled] records that stopping really
/// tore the turn down instead of leaving it running behind the UI.
class _OpenEndedSender implements ChatSender {
  late final StreamController<ChatSendUpdate> _controller =
      StreamController<ChatSendUpdate>(onCancel: () => cancelled = true);

  bool cancelled = false;

  void emit(ChatSendUpdate update) => _controller.add(update);

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) => _controller.stream;
}

/// An open-ended reply per conversation, so a test can have several chats
/// streaming at once and drive each independently — keyed by the conversation id
/// the send carries.
class _PerChatSender implements ChatSender {
  final controllers = <String, StreamController<ChatSendUpdate>>{};
  final cancelled = <String>{};

  void emit(String conversationId, ChatSendUpdate update) =>
      controllers[conversationId]!.add(update);

  Future<void> close(String conversationId) =>
      controllers[conversationId]!.close();

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    final id = conversationId!;
    final controller = controllers[id] = StreamController<ChatSendUpdate>(
      onCancel: () => cancelled.add(id),
    );
    return controller.stream;
  }
}

/// A fixed selected grid, so approving a plan (which reads the current grid to
/// send the execute turn) never touches the real `~/.grid`.
class _FixedNetwork extends SelectedNetwork {
  @override
  NetworkCredential? build() => _credential();
}

/// The agent's own name for a session, handed back the moment it's asked for —
/// unless [held] is set, in which case it waits for [release].
///
/// The real one takes seconds (it polls the agent), and that gap is where the
/// user gets to rename the chat themselves. A fake that answers instantly closes
/// the gap and would let a race through untested.
class _FakeAgentTitle implements AgentSessionTitle {
  _FakeAgentTitle(this.title, {this.held = false});

  final String? title;
  final bool held;
  final asked = <String>[];
  final _gate = Completer<void>();

  /// Let the held name land, as the agent eventually would.
  void release() => _gate.complete();

  @override
  Future<String?> waitFor(String sessionId) async {
    asked.add(sessionId);
    if (held) await _gate.future;
    return title;
  }
}

/// A grid whose machines are known — what a reply's "on which machine" is read
/// off. Empty by default: most tests care about the turn, not the grid.
GridOverview _overview({List<OverviewNode> nodes = const []}) => GridOverview(
  stats: GridStats(models: 0, nodes: nodes.length),
  models: const [],
  nodes: nodes,
);

/// One online machine on the grid, serving [models].
OverviewNode _node(String name, {List<String> models = const []}) =>
    OverviewNode(name: name, online: true, engine: 'llama.cpp', models: models);

/// A controller wired to a temp-dir store, a fake relay sender and a fake agent
/// (hermes) sender, so a test can assert which of the two a send was routed to.
({
  ProviderContainer container,
  ChatStore store,
  _FakeSender sender,
  _FakeSender agent,
  _FakeAgentTitle agentTitle,
})
_harness(
  Directory dir, {
  required List<ChatSendUpdate> updates,
  bool agentInstalled = false,
  String? agentName,
  bool holdAgentName = false,
  ChatSender? answering,
  GridOverview? overview,
}) {
  final store = ChatStore(directory: dir);
  final sender = _FakeSender(updates);
  final agent = _FakeSender(updates);
  final agentTitle = _FakeAgentTitle(agentName, held: holdAgentName);
  final container = ProviderContainer(
    overrides: [
      chatStoreProvider.overrideWithValue(store),
      // [answering] stands in for whoever replies, for a test that cares about
      // the reply arriving over time rather than about who sent it.
      chatSenderProvider.overrideWithValue(answering ?? sender),
      hermesChatSenderProvider.overrideWithValue(answering ?? agent),
      agentSessionTitleProvider.overrideWithValue(agentTitle),
      // Keep any saved input images in the temp dir, never the real grid home.
      mediaOutputsDirProvider.overrideWithValue(
        Directory('${dir.path}/outputs'),
      ),
      // Whether this computer has the agent — the one thing that decides who
      // answers a plain text turn. Every other agent is pinned absent so the
      // real machine's PATH (which may have any of them installed) can't leak
      // in, pick a different agent, and spawn a real process mid-test. Pi went
      // missing from this list when it was added to the catalog, and on a
      // machine with `pi` installed it took over every turn: eleven tests then
      // waited on a real process for their reply and never got one.
      hermesPathProvider.overrideWithValue(
        agentInstalled ? '/bin/hermes' : null,
      ),
      codexPathProvider.overrideWithValue(null),
      claudePathProvider.overrideWithValue(null),
      piPathProvider.overrideWithValue(null),
      // The grid a reply is stamped with — offline, like everything else here.
      // Without it, sending a turn would reach for the live overview.
      // Returned, not awaited: a turn reads the last snapshot as it goes out,
      // and a future that resolves next microtask is a snapshot it can't see.
      gridOverviewProvider.overrideWith((ref) => overview ?? _overview()),
      // Keep the remembered model and the projects off the real `~/.grid`.
      chatPrefsStoreProvider.overrideWithValue(
        ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
      ),
      projectsStoreProvider.overrideWithValue(
        ProjectsStore(file: File('${dir.path}/projects.json')),
      ),
      // Approving a plan reads the current grid; keep it off the real home.
      selectedNetworkProvider.overrideWith(_FixedNetwork.new),
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    store: store,
    sender: sender,
    agent: agent,
    agentTitle: agentTitle,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_chat_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  test(
    'a streamed reply is timed twice — when it started answering and when '
    'it finished — so the footer can tell a slow model from a slow start',
    () async {
      final h = _harness(
        tmp,
        updates: [
          const ChatSendStreaming('Hel'),
          const ChatSendStreaming('Hello there'),
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'Hello there'),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      final reply = h.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .messages
          .last;
      // Real clocks, so the assertion is on the relationship, not the numbers:
      // the first word can't land after the turn ended, and both are recorded.
      expect(reply.firstToken, isNotNull);
      expect(reply.took, isNotNull);
      expect(reply.firstToken! <= reply.took!, isTrue);
    },
  );

  test('a reply that never streamed carries no first-word time, rather than '
      'one equal to the total', () async {
    final h = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'hi back'),
        ),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');

    final reply = h.container
        .read(chatSessionsProvider)
        .conversations
        .single
        .messages
        .last;
    expect(reply.firstToken, isNull);
    expect(reply.took, isNotNull);
  });

  test('a reply says which agent wrote it, so a chat that changed agent '
      'half-way still tells you who answered what', () async {
    final viaAgent = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'hi back'),
        ),
      ],
    );

    await viaAgent.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');

    expect(
      viaAgent.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .messages
          .last
          .agent,
      'hermes',
    );

    // And with no agent on the computer the grid answered it itself — which is
    // a different thing, so the footer must not credit an agent for it.
    final viaGrid = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'hi back'),
        ),
      ],
    );

    await viaGrid.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');

    expect(
      viaGrid.container
          .read(chatSessionsProvider)
          .conversations
          .last
          .messages
          .last
          .agent,
      isNull,
    );
  });

  test('a reply names the machine that served the model, and leaves it unnamed '
      'when the grid has not said which one that is', () async {
    final h = _harness(
      tmp,
      overview: _overview(
        nodes: [
          _node('doggi', models: ['qwen']),
        ],
      ),
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'hi back'),
        ),
      ],
    );
    final chat = h.container.read(chatSessionsProvider.notifier);

    await chat.send(network: _credential(), model: 'qwen', message: 'hi');
    expect(
      h.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .messages
          .last
          .node,
      'doggi',
    );

    // The router picks per request and never says which machine took it, so a
    // reply answered through it names none rather than the one node in sight.
    chat.newChat();
    await chat.send(network: _credential(), model: 'auto', message: 'hi');
    expect(
      h.container
          .read(chatSessionsProvider)
          .conversations
          .first
          .messages
          .last
          .node,
      isNull,
    );
  });

  test(
    'send creates a conversation, appends the reply and persists it',
    () async {
      final h = _harness(
        tmp,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'hi back'),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      final state = h.container.read(chatSessionsProvider);
      expect(state.sending, isFalse);
      expect(state.error, isNull);
      expect(state.conversations, hasLength(1));

      final conv = state.conversations.single;
      expect(state.activeId, conv.id);
      expect(conv.model, 'qwen');
      expect(conv.title, 'hi');
      expect(conv.messages.map((m) => m.role).toList(), [
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(conv.messages.last.text, 'hi back');

      // The sender saw the running history (with the user turn appended).
      expect(h.sender.history!.single.text, 'hi');

      // Persisted to disk and reloadable.
      final reloaded = await ChatStore(directory: tmp).loadAll();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.messages.last.text, 'hi back');
    },
  );

  test(
    'a failed turn keeps the partial reply it built — its prose and plan — and '
    'still shows the error, instead of wiping the chat blank',
    () async {
      final h = _harness(
        tmp,
        updates: [
          const ChatSendStreaming("Here's my plan"),
          ChatSendFailure(
            'The agent planned the work but stopped before finishing it.',
            partial: const ChatMessage(
              role: ChatRole.assistant,
              text: "Here's my plan",
              plan: [
                AgentPlanEntry(
                  content: 'Build it',
                  status: AgentPlanStatus.pending,
                ),
              ],
            ),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'build a game');

      final state = h.container.read(chatSessionsProvider);
      final conv = state.conversations.single;
      // The partial assistant turn — its prose and the plan it laid out — is
      // kept, stamped with the model that produced it.
      expect(conv.messages.map((m) => m.role).toList(), [
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(conv.messages.last.text, "Here's my plan");
      expect(conv.messages.last.plan, hasLength(1));
      expect(conv.messages.last.model, 'qwen');
      // The error still shows above it, with its retry affordance.
      expect(
        state.error,
        'The agent planned the work but stopped before finishing it.',
      );
      // And it is persisted, not only held in memory.
      expect(
        (await ChatStore(directory: tmp).loadAll()).single.messages.last.text,
        "Here's my plan",
      );
    },
  );

  test(
    'a turn that fails mid-stream with no structured partial keeps the text it '
    'had already streamed (the relay path)',
    () async {
      final h = _harness(
        tmp,
        updates: const [
          ChatSendStreaming('A grid is your private'),
          ChatSendFailure('The grid stopped answering.'),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(
            network: _credential(),
            model: 'qwen',
            message: 'what is a grid',
          );

      final state = h.container.read(chatSessionsProvider);
      final conv = state.conversations.single;
      expect(conv.messages.last.role, ChatRole.assistant);
      expect(conv.messages.last.text, 'A grid is your private');
      expect(state.error, 'The grid stopped answering.');
    },
  );

  test(
    'a turn that fails before saying anything shows only the error — no empty '
    'assistant bubble',
    () async {
      final h = _harness(
        tmp,
        updates: const [ChatSendFailure('Could not start the assistant.')],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      final state = h.container.read(chatSessionsProvider);
      final conv = state.conversations.single;
      expect(conv.messages.map((m) => m.role).toList(), [ChatRole.user]);
      expect(state.error, 'Could not start the assistant.');
    },
  );

  group('concurrent sessions', () {
    test('a second chat can be started and stream while the first is still '
        'generating — neither blocks the other, and each reply folds into its '
        'own transcript without stealing focus', () async {
      final answering = _PerChatSender();
      final h = _harness(tmp, updates: const [], answering: answering);
      final c = h.container.read(chatSessionsProvider.notifier);
      ChatSessionsState read() => h.container.read(chatSessionsProvider);

      // Chat A starts generating.
      final sentA = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'first',
      );
      await pumpEventQueue();
      final aId = read().activeId!;
      answering.emit(aId, const ChatSendStreaming('working on first'));
      await pumpEventQueue();

      // Starting a new chat is NOT blocked by A still streaming (the bug).
      c.newChat();
      expect(read().activeId, isNull);

      // Chat B starts and streams too — both are now in flight at once.
      final sentB = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'second',
      );
      await pumpEventQueue();
      final bId = read().activeId!;
      expect(bId, isNot(aId));
      expect(read().sendingFor(aId), isTrue);
      expect(read().sendingFor(bId), isTrue);

      // Switching to A mid-send is allowed and doesn't derail B.
      c.select(aId);
      expect(read().activeId, aId);
      expect(read().sending, isTrue); // A, now open, is the one streaming

      // B's reply lands while A is open: it folds into B and must not yank the
      // user off A.
      answering.emit(
        bId,
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'done second'),
        ),
      );
      await answering.close(bId);
      await sentB;
      expect(read().activeId, aId, reason: 'a background reply keeps focus');
      expect(read().sendingFor(bId), isFalse);

      // A's reply lands into A.
      answering.emit(
        aId,
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'done first'),
        ),
      );
      await answering.close(aId);
      await sentA;

      final s = read();
      expect(s.sending, isFalse);
      final a = s.conversations.firstWhere((x) => x.id == aId);
      final b = s.conversations.firstWhere((x) => x.id == bId);
      expect(a.messages.last.text, 'done first');
      expect(b.messages.last.text, 'done second');
    });

    test(
      'stopping the open chat leaves another chat still streaming',
      () async {
        final answering = _PerChatSender();
        final h = _harness(tmp, updates: const [], answering: answering);
        final c = h.container.read(chatSessionsProvider.notifier);
        ChatSessionsState read() => h.container.read(chatSessionsProvider);

        final sentA = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'first',
        );
        await pumpEventQueue();
        final aId = read().activeId!;
        c.newChat();
        final sentB = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'second',
        );
        await pumpEventQueue();
        final bId = read().activeId!;

        // Stop targets the open chat (B) only.
        c.stop();
        expect(answering.cancelled.contains(bId), isTrue);
        expect(answering.cancelled.contains(aId), isFalse);
        expect(read().sendingFor(bId), isFalse);
        expect(read().sendingFor(aId), isTrue, reason: 'A keeps streaming');

        answering.emit(
          aId,
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'done first'),
          ),
        );
        await answering.close(aId);
        await sentA;
        expect(read().sendingFor(aId), isFalse);
        await sentB;
      },
    );
  });

  group('agent turns take turns per project', () {
    test('a second agent turn in the same project waits for the first — two '
        'agents let loose in one folder would edit the same files', () async {
      final answering = _PerChatSender();
      final h = _harness(
        tmp,
        updates: const [],
        agentInstalled: true,
        answering: answering,
      );
      final c = h.container.read(chatSessionsProvider.notifier);
      ChatSessionsState read() => h.container.read(chatSessionsProvider);
      final project = h.container
          .read(projectsProvider.notifier)
          .add('${tmp.path}/api');

      // Chat A (giá vàng) starts on the agent, inside the project.
      c.newChat(projectId: project.id);
      final sentA = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'giá vàng hôm nay',
      );
      await pumpEventQueue();
      final aId = read().activeId!;
      expect(answering.controllers.containsKey(aId), isTrue);
      expect(
        read().agentRunningIn(aId),
        isTrue,
        reason: "A holds its project's lane",
      );

      // Chat B (tin thế giới) is sent into the same project while A is still
      // generating. It must NOT reach the agent yet — it waits in the lane,
      // showing its own busy state.
      c.newChat(projectId: project.id);
      final sentB = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'tin thế giới',
      );
      await pumpEventQueue();
      final bId = read().activeId!;
      expect(bId, isNot(aId));
      expect(
        answering.controllers.containsKey(bId),
        isFalse,
        reason: 'the second turn in this project is queued, not dispatched',
      );
      expect(read().sendingFor(aId), isTrue);
      expect(
        read().sendingFor(bId),
        isTrue,
        reason: 'B waits in its busy state',
      );
      expect(read().agentRunningIn(bId), isFalse);
      // Only B is waiting on the lane, and the transcript's "finishing another
      // chat in this project…" is drawn from exactly this. A is running, so it
      // must not claim to be waiting on itself.
      expect(read().laneQueuedIn(bId), isTrue);
      expect(read().laneQueuedIn(aId), isFalse);

      // A finishes. Only now does B reach the agent — and A never hung.
      answering.emit(
        aId,
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'giá vàng: ...'),
        ),
      );
      await answering.close(aId);
      await sentA;
      await pumpEventQueue();
      expect(read().sendingFor(aId), isFalse);
      expect(
        answering.controllers.containsKey(bId),
        isTrue,
        reason: 'B dispatches once the lane frees',
      );
      expect(read().agentRunningIn(bId), isTrue);
      expect(
        read().laneQueuedIn(bId),
        isFalse,
        reason: 'it is no longer waiting for anything — it is answering',
      );

      answering.emit(
        bId,
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'tin thế giới: ...'),
        ),
      );
      await answering.close(bId);
      await sentB;

      final s = read();
      expect(s.sending, isFalse);
      expect(s.runningAgentIds, isEmpty, reason: 'no agent turn left running');
      final a = s.conversations.firstWhere((x) => x.id == aId);
      final b = s.conversations.firstWhere((x) => x.id == bId);
      expect(a.messages.last.text, 'giá vàng: ...');
      expect(b.messages.last.text, 'tin thế giới: ...');
    });

    test('two projects answer at the same time — a chat about one folder never '
        'waits on work in a folder it has never heard of', () async {
      final answering = _PerChatSender();
      final h = _harness(
        tmp,
        updates: const [],
        agentInstalled: true,
        answering: answering,
      );
      final c = h.container.read(chatSessionsProvider.notifier);
      ChatSessionsState read() => h.container.read(chatSessionsProvider);
      final projects = h.container.read(projectsProvider.notifier);
      final api = projects.add('${tmp.path}/api');
      final web = projects.add('${tmp.path}/web');

      c.newChat(projectId: api.id);
      final sentA = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'fix the api',
      );
      await pumpEventQueue();
      final aId = read().activeId!;

      c.newChat(projectId: web.id);
      final sentB = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'fix the web app',
      );
      await pumpEventQueue();
      final bId = read().activeId!;

      expect(
        answering.controllers.containsKey(bId),
        isTrue,
        reason: 'another project has its own lane — nothing to wait for',
      );
      expect(read().runningAgentIds, {aId, bId});

      for (final id in [aId, bId]) {
        answering.emit(
          id,
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'done'),
          ),
        );
        await answering.close(id);
      }
      await sentA;
      await sentB;
      expect(read().runningAgentIds, isEmpty);
    });

    test(
      'chats outside every project never queue — there is no folder for them '
      'to collide in',
      () async {
        final answering = _PerChatSender();
        final h = _harness(
          tmp,
          updates: const [],
          agentInstalled: true,
          answering: answering,
        );
        final c = h.container.read(chatSessionsProvider.notifier);
        ChatSessionsState read() => h.container.read(chatSessionsProvider);

        final sentA = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'first',
        );
        await pumpEventQueue();
        final aId = read().activeId!;

        c.newChat();
        final sentB = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'second',
        );
        await pumpEventQueue();
        final bId = read().activeId!;

        expect(answering.controllers.containsKey(bId), isTrue);
        expect(read().runningAgentIds, {aId, bId});

        for (final id in [aId, bId]) {
          answering.emit(
            id,
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'done'),
            ),
          );
          await answering.close(id);
        }
        await sentA;
        await sentB;
      },
    );

    test(
      'deleting the chat holding a project lane lets the queued one run — '
      'a cancelled turn must not strand the ones waiting behind it',
      () async {
        final answering = _PerChatSender();
        final h = _harness(
          tmp,
          updates: const [],
          agentInstalled: true,
          answering: answering,
        );
        final c = h.container.read(chatSessionsProvider.notifier);
        ChatSessionsState read() => h.container.read(chatSessionsProvider);
        final project = h.container
            .read(projectsProvider.notifier)
            .add('${tmp.path}/api');

        c.newChat(projectId: project.id);
        final sentA = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'first',
        );
        await pumpEventQueue();
        final aId = read().activeId!;
        c.newChat(projectId: project.id);
        final sentB = c.send(
          network: _credential(),
          model: 'qwen',
          message: 'second',
        );
        await pumpEventQueue();
        final bId = read().activeId!;
        expect(answering.controllers.containsKey(bId), isFalse);

        // Delete A while it holds the lane: B must not wait forever.
        c.deleteConversation(aId);
        await sentA;
        await pumpEventQueue();
        expect(
          answering.controllers.containsKey(bId),
          isTrue,
          reason: 'B runs once A releases the lane',
        );
        expect(read().sendingFor(bId), isTrue);

        answering.emit(
          bId,
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'done second'),
          ),
        );
        await answering.close(bId);
        await sentB;
        expect(read().sendingFor(bId), isFalse);
      },
    );
  });

  group('stop', () {
    test('keeps what the assistant had already said — the user stopped because '
        'they had read enough of it, not to throw it away', () async {
      final answering = _OpenEndedSender();
      final h = _harness(tmp, updates: const [], answering: answering);
      final controller = h.container.read(chatSessionsProvider.notifier);

      final sent = controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'explain grids',
      );
      await pumpEventQueue();
      answering.emit(const ChatSendStreaming('A grid is your private'));
      await pumpEventQueue();

      controller.stop();
      await sent;

      final state = h.container.read(chatSessionsProvider);
      expect(state.sending, isFalse);
      expect(
        answering.cancelled,
        isTrue,
        reason: 'the turn is really torn down',
      );

      final messages = state.conversations.single.messages;
      expect(messages.map((m) => m.role).toList(), [
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(messages.last.text, 'A grid is your private');
      // On disk too — a stopped answer survives closing the app.
      expect(
        (await ChatStore(directory: tmp).loadAll()).single.messages.last.text,
        'A grid is your private',
      );
    });

    test(
      'stopping before a single word arrived leaves no empty reply behind',
      () async {
        final answering = _OpenEndedSender();
        final h = _harness(tmp, updates: const [], answering: answering);
        final controller = h.container.read(chatSessionsProvider.notifier);

        final sent = controller.send(
          network: _credential(),
          model: 'qwen',
          message: 'explain grids',
        );
        await pumpEventQueue();

        controller.stop();
        await sent;

        final state = h.container.read(chatSessionsProvider);
        expect(state.sending, isFalse);
        expect(state.conversations.single.messages.single.role, ChatRole.user);
      },
    );
  });

  test(
    'a failure keeps the user message, sets the error and persists it',
    () async {
      final h = _harness(
        tmp,
        updates: [const ChatSendFailure('provider offline')],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      final state = h.container.read(chatSessionsProvider);
      expect(state.error, 'provider offline');
      expect(state.sending, isFalse);
      expect(state.conversations.single.messages, hasLength(1));
      expect(state.conversations.single.messages.single.role, ChatRole.user);

      final reloaded = await ChatStore(directory: tmp).loadAll();
      expect(reloaded.single.messages.single.text, 'hi');
    },
  );

  test(
    'handing the chat to another agent takes the old failure with it',
    () async {
      // The sentence blamed an agent that no longer answers, and it sat right
      // above the button that had just switched away from it — which then offered
      // to switch back. Keeps the transcript, drops only the message.
      final h = _harness(
        tmp,
        updates: [const ChatSendFailure('provider offline')],
      );
      final controller = h.container.read(chatSessionsProvider.notifier);
      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'hi',
      );

      controller.clearError();

      final state = h.container.read(chatSessionsProvider);
      expect(state.error, isNull);
      expect(state.conversations.single.messages, hasLength(1));
    },
  );

  test('an attached image is saved onto the user turn and persists', () async {
    final h = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'a cat'),
        ),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(
          network: _credential(),
          model: 'vision',
          message: 'what is this?',
          attachments: [
            MediaAttachment(
              filename: 'pic.png',
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
        );

    final conv = h.container.read(chatSessionsProvider).conversations.single;
    final userMsg = conv.messages.first;
    expect(userMsg.media, hasLength(1));
    expect(userMsg.media.single.kind, MediaKind.image);
    expect(File(userMsg.media.single.path).existsSync(), isTrue);

    // The saved image path survives a reload from disk.
    final reloaded = (await ChatStore(directory: tmp).loadAll()).single;
    expect(
      reloaded.messages.first.media.single.path,
      userMsg.media.single.path,
    );
  });

  test('a second turn appends to the same open conversation', () async {
    final h = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'a1'),
        ),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'q1');
    await controller.send(network: _credential(), model: 'm', message: 'q2');

    final state = h.container.read(chatSessionsProvider);
    expect(state.conversations, hasLength(1));
    expect(state.conversations.single.messages.map((m) => m.text).toList(), [
      'q1',
      'a1',
      'q2',
      'a1',
    ]);
  });

  test('a text turn goes through the agent when it is installed', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');

    expect(h.agent.modality, PlaygroundModality.text);
    expect(h.sender.history, isNull);
  });

  test('an image model generates through the API, agent or not', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(
          network: _credential(),
          model: 'flux',
          message: 'a stormy sky',
          modality: PlaygroundModality.image,
        );

    // The (text-only) agent never sees it: the API sender generates the image.
    expect(h.agent.history, isNull);
    expect(h.sender.modality, PlaygroundModality.image);
    expect(h.sender.model, 'flux');
  });

  test('a text turn with an attached image goes to the API', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(
          network: _credential(),
          model: 'qwen',
          message: 'what is in this picture?',
          attachments: [
            MediaAttachment(
              filename: 'shot.png',
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
        );

    // Only the API sender can see a picture, so the agent must not swallow it.
    expect(h.agent.history, isNull);
    expect(h.sender.attachments, hasLength(1));
  });

  test('newChat starts a fresh compose without losing history', () async {
    final h = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'q1');
    controller.newChat();

    var state = h.container.read(chatSessionsProvider);
    expect(state.activeId, isNull);
    expect(state.conversations, hasLength(1));

    // Sending now spawns a second conversation.
    await controller.send(network: _credential(), model: 'm', message: 'q2');
    state = h.container.read(chatSessionsProvider);
    expect(state.conversations, hasLength(2));
  });

  test('deleteConversation removes it from state and disk', () async {
    final h = _harness(
      tmp,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'q');
    final id = h.container.read(chatSessionsProvider).conversations.single.id;

    controller.deleteConversation(id);

    final state = h.container.read(chatSessionsProvider);
    expect(state.conversations, isEmpty);
    expect(state.activeId, isNull);
    expect(await ChatStore(directory: tmp).loadAll(), isEmpty);
  });

  test('loads saved conversations on build and opens the newest', () async {
    final store = ChatStore(directory: tmp);
    store.save(
      Conversation(
        id: 'old',
        title: 'Older one',
        model: 'm',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        messages: const [ChatMessage(role: ChatRole.user, text: 'hey')],
      ),
    );
    store.save(
      Conversation(
        id: 'new',
        title: 'Newer one',
        model: 'm',
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 1),
      ),
    );

    final container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(store),
        chatSenderProvider.overrideWithValue(_FakeSender(const [])),
      ],
    );
    addTearDown(container.dispose);

    // Nothing is read on the first frame — the rail says so rather than
    // claiming an empty history.
    expect(container.read(chatSessionsProvider).loading, isTrue);
    await container.read(chatSessionsProvider.notifier).restored;

    final state = container.read(chatSessionsProvider);
    expect(state.loading, isFalse);
    expect(state.conversations, hasLength(2));
    expect(state.activeId, 'new'); // newest-first
  });

  test('a chat opened inside a project sends that folder to the agent — which '
      'is what lets it read the user\'s files', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final project = h.container
        .read(projectsProvider.notifier)
        .add('${tmp.path}/my-notes');

    h.container
        .read(chatSessionsProvider.notifier)
        .newChat(projectId: project.id);
    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'what changed?');

    expect(h.agent.workdir, project.path);
    // And the chat remembers its project across a reload from disk.
    final reloaded = (await ChatStore(directory: tmp).loadAll()).single;
    expect(reloaded.projectId, project.id);
  });

  test('a new chat in a project exposes that project before its first message, '
      'so the pane shows the project rail from the very first "New chat"', () {
    final h = _harness(tmp, updates: const []);
    final project = h.container
        .read(projectsProvider.notifier)
        .add('${tmp.path}/my-notes');

    h.container
        .read(chatSessionsProvider.notifier)
        .newChat(projectId: project.id);

    final state = h.container.read(chatSessionsProvider);
    // The draft isn't saved yet — there's no active conversation to read a
    // project off of — but the pane can still tell which project it's in.
    expect(state.active, isNull);
    expect(state.openProjectId, project.id);
  });

  test('a plain new chat belongs to no project', () {
    final h = _harness(tmp, updates: const []);

    h.container.read(chatSessionsProvider.notifier).newChat();

    expect(h.container.read(chatSessionsProvider).openProjectId, isNull);
  });

  test(
    'the chat is named by the agent, not by the first thing typed',
    () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        agentName: 'Kiểm tra thư mục dự án Flutter',
        updates: [
          const ChatSendAgentSession('sess-1'),
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');
      // The name lands after the reply, so let the wait for it settle.
      await pumpEventQueue();

      final state = h.container.read(chatSessionsProvider);
      final conv = state.conversations.single;
      expect(h.agentTitle.asked, ['sess-1']);
      expect(conv.title, 'Kiểm tra thư mục dự án Flutter');
      // Renaming doesn't move the chat or steal the open one.
      expect(state.activeId, conv.id);
      // And the name is on disk, not just on screen.
      expect(
        (await ChatStore(directory: tmp).loadAll()).single.title,
        conv.title,
      );
    },
  );

  test('an unnamed session leaves the chat with the name it had', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');
    await pumpEventQueue();

    expect(
      h.container.read(chatSessionsProvider).conversations.single.title,
      'hi',
    );
  });

  test('only the opening exchange names the chat — a later turn keeps the name '
      'instead of dragging it back to the first line typed', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      agentName: 'Đọc thư mục dự án',
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'hi');
    await pumpEventQueue();
    await controller.send(network: _credential(), model: 'm', message: 'more');
    await pumpEventQueue();

    // Named once, off the opening exchange...
    expect(h.agentTitle.asked, ['sess-1']);
    // ...and the second turn didn't re-derive it back to 'hi'.
    final conv = h.container.read(chatSessionsProvider).conversations.single;
    expect(conv.title, 'Đọc thư mục dự án');
    expect(
      (await ChatStore(directory: tmp).loadAll()).single.title,
      conv.title,
    );
  });

  test('a name the user typed survives the agent naming the same chat — the '
      'agent name arrives seconds late and must not overwrite it', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      agentName: 'Đọc thư mục dự án',
      // Held, so the name is still in flight while the user renames — the real
      // wait is seconds long, which is ample time to open the "…" menu.
      holdAgentName: true,
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'hi');
    final id = h.container.read(chatSessionsProvider).conversations.single.id;
    controller.renameConversation(id, 'Ngân sách quý 4');
    // Only now does the agent's name arrive — onto a chat the user has named.
    h.agentTitle.release();
    await pumpEventQueue();

    final conv = h.container.read(chatSessionsProvider).conversations.single;
    expect(conv.title, 'Ngân sách quý 4');
    expect(conv.titleLocked, isTrue);
    // On disk too, so reopening the app doesn't restore the agent's name.
    expect(
      (await ChatStore(directory: tmp).loadAll()).single.title,
      'Ngân sách quý 4',
    );
  });

  test('the lock outlives a restart — a chat reloaded from disk still refuses '
      'to be renamed by the agent', () async {
    final store = ChatStore(directory: tmp);
    store.save(
      Conversation(
        id: 'c1',
        title: 'Ngân sách quý 4',
        model: 'm',
        createdAt: DateTime(2026, 7, 1),
        updatedAt: DateTime(2026, 7, 1),
        titleLocked: true,
      ),
    );

    expect((await store.loadAll()).single.titleLocked, isTrue);
  });

  test('a chat with no project sends no folder — the agent falls back to its '
      'own', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');

    expect(h.agent.workdir, isNull);
  });

  group('setActiveModel', () {
    test('remembers the picked model on the open chat and persists it — so '
        'leaving and returning restores it, not the grid default', () async {
      final h = _harness(
        tmp,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );
      final controller = h.container.read(chatSessionsProvider.notifier);
      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'q',
      );
      final before = h.container.read(chatSessionsProvider).active!;

      controller.setActiveModel('deepreinforce-ai/ornith-1.0-35b');

      final after = h.container.read(chatSessionsProvider).active!;
      expect(after.model, 'deepreinforce-ai/ornith-1.0-35b');
      // Picking a model must not bump the chat to the top of the sidebar.
      expect(after.updatedAt, before.updatedAt);
      // Persisted, so a reload (next launch) keeps the choice.
      expect(
        (await ChatStore(directory: tmp).loadAll()).single.model,
        'deepreinforce-ai/ornith-1.0-35b',
      );
    });

    test(
      'is a no-op for a not-yet-saved compose — nothing to persist yet',
      () async {
        final h = _harness(tmp, updates: const []);
        final controller = h.container.read(chatSessionsProvider.notifier);
        controller.newChat();

        controller.setActiveModel('ornith-35b');

        expect(h.container.read(chatSessionsProvider).active, isNull);
        expect(await ChatStore(directory: tmp).loadAll(), isEmpty);
      },
    );
  });

  group('Plan mode', () {
    ({ProviderContainer container, _FakeSender agent}) planHarness() {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'My plan: 1) …'),
          ),
        ],
      );
      h.container
          .read(chatPrefsProvider.notifier)
          .setApproval(AgentApprovalMode.plan);
      return (container: h.container, agent: h.agent);
    }

    test(
      'a Plan-mode send runs a planning turn and leaves the plan waiting for '
      'approval',
      () async {
        final h = planHarness();

        await h.container
            .read(chatSessionsProvider.notifier)
            .send(
              network: _credential(),
              model: 'qwen',
              message: 'refactor it',
            );

        expect(h.container.read(chatSessionsProvider).awaitingPlan, isTrue);
        // The agent ran it as a planning turn (read-only, plan preamble).
        expect(h.agent.planFirsts, [true]);
      },
    );

    test('approving the plan runs a second turn to carry it out, and clears the '
        'bar', () async {
      final h = planHarness();
      final controller = h.container.read(chatSessionsProvider.notifier);

      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'refactor it',
      );
      await controller.approvePlan();

      // Two turns: the plan, then the execute turn — which is NOT a plan turn.
      expect(h.agent.planFirsts, [true, false]);
      expect(h.container.read(chatSessionsProvider).awaitingPlan, isFalse);
    });

    test(
      'dismissing the plan clears the bar without running anything',
      () async {
        final h = planHarness();
        final controller = h.container.read(chatSessionsProvider.notifier);

        await controller.send(
          network: _credential(),
          model: 'qwen',
          message: 'refactor it',
        );
        controller.dismissPlan();

        expect(h.container.read(chatSessionsProvider).awaitingPlan, isFalse);
        // Only the planning turn ran; nothing was executed.
        expect(h.agent.planFirsts, [true]);
      },
    );

    test('an ordinary send never leaves a plan waiting', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'hi back'),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      expect(h.container.read(chatSessionsProvider).awaitingPlan, isFalse);
      expect(h.agent.planFirsts, [false]);
    });
  });

  group('a turn that ran out of tool calls', () {
    ({ProviderContainer container, _FakeSender agent}) cappedHarness() {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'Got three of five.'),
            outOfSteps: true,
          ),
        ],
      );
      return (container: h.container, agent: h.agent);
    }

    test(
      'is offered a way on rather than passed off as finished work',
      () async {
        final h = cappedHarness();

        await h.container
            .read(chatSessionsProvider.notifier)
            .send(network: _credential(), model: 'qwen', message: 'do the lot');

        expect(h.container.read(chatSessionsProvider).outOfSteps, isTrue);
      },
    );

    test('carrying on spends a fresh turn, and the offer goes away when that '
        'turn finishes the work', () async {
      final scripted = _ScriptedSender([
        const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'Got three of five.'),
            outOfSteps: true,
          ),
        ],
        const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'Finished the rest.'),
          ),
        ],
      ]);
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [],
        answering: scripted,
      );
      final controller = h.container.read(chatSessionsProvider.notifier);

      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'do the lot',
      );
      await controller.continueTurn();

      // A second turn really went out — a fresh budget is the whole point — and
      // its ordinary reply leaves nothing to carry on from.
      expect(scripted.calls, 2);
      expect(h.container.read(chatSessionsProvider).outOfSteps, isFalse);
    });

    test(
      'waving the offer away sends nothing — stopping short may be fine',
      () async {
        final h = cappedHarness();
        final controller = h.container.read(chatSessionsProvider.notifier);

        await controller.send(
          network: _credential(),
          model: 'qwen',
          message: 'do the lot',
        );
        controller.dismissOutOfSteps();

        expect(h.container.read(chatSessionsProvider).outOfSteps, isFalse);
        expect(h.agent.planFirsts, [false]);
      },
    );

    test('an ordinary reply leaves the offer dark, so it means something when '
        'it does appear', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'All done.'),
          ),
        ],
      );

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'do the lot');

      expect(h.container.read(chatSessionsProvider).outOfSteps, isFalse);
    });
  });

  group('how much the assistant may do belongs to the chat', () {
    test('full access granted for one job does not follow the user into the '
        'next chat', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      // The user's standing choice, set on a blank composer: ask me first.
      chats.setApproval(AgentApprovalMode.ask);

      // Chat one: the user hands the agent the keys to get a job done.
      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'rebuild the project',
      );
      chats.setApproval(AgentApprovalMode.full);
      final first = h.container.read(chatSessionsProvider).activeId!;

      // Chat two, about something else entirely.
      chats.newChat();
      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'what does this file do?',
      );
      final second = h.container.read(chatSessionsProvider).activeId!;

      expect(first, isNot(second));
      // The second turn went out under the standing choice, not under the
      // access the first chat was given.
      expect(h.agent.approvals.last, AgentApprovalMode.ask);
      // And going back to the first chat still shows what it was set to.
      chats.select(first);
      expect(
        h.container.read(chatApprovalModeProvider),
        AgentApprovalMode.full,
      );
    });

    test(
      'a chat that has never been told follows the app\'s standing choice',
      () async {
        final h = _harness(
          tmp,
          agentInstalled: true,
          updates: const [
            ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
          ],
        );
        // Nothing open: the pick sets the standing choice rather than a chat.
        h.container
            .read(chatSessionsProvider.notifier)
            .setApproval(AgentApprovalMode.readOnly);

        await h.container
            .read(chatSessionsProvider.notifier)
            .send(network: _credential(), model: 'qwen', message: 'hi');

        expect(h.agent.approvals.single, AgentApprovalMode.readOnly);
        expect(
          h.container.read(chatSessionsProvider).conversations.single.approval,
          isNull,
          reason: 'the chat follows the setting rather than freezing a copy',
        );
      },
    );

    test('the mode a chat was set to survives a restart — it decides what the '
        'agent may do to the computer', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
        ],
      );
      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');
      h.container
          .read(chatSessionsProvider.notifier)
          .setApproval(AgentApprovalMode.readOnly);

      final reopened = (await h.store.loadAll()).single;
      expect(reopened.approval, AgentApprovalMode.readOnly);
    });
  });

  group('a follow-up typed while the agent is still working', () {
    test('is queued and sent when the turn finishes, instead of being '
        'dropped', () async {
      final sender = _PerChatSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [],
        answering: sender,
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'first'),
      );
      await Future<void>.delayed(Duration.zero);
      final id = h.container.read(chatSessionsProvider).activeId!;

      // The user thinks of something else while the first answer streams.
      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'second'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        h.container.read(chatSessionsProvider).queuedFor(id).single.text,
        'second',
      );
      // Still one user turn: the follow-up has not gone out yet.
      expect(_userTurns(h.container, id), ['first']);

      sender.emit(
        id,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      );
      await sender.close(id);
      await Future<void>.delayed(Duration.zero);

      expect(h.container.read(chatSessionsProvider).queuedFor(id), isEmpty);
      expect(_userTurns(h.container, id), ['first', 'second']);
    });

    test('goes out in the chat it was typed in, even after the user has moved '
        'to another one', () async {
      final sender = _PerChatSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [],
        answering: sender,
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'first'),
      );
      await Future<void>.delayed(Duration.zero);
      final first = h.container.read(chatSessionsProvider).activeId!;
      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'second'),
      );
      await Future<void>.delayed(Duration.zero);

      // They wander off to start a different conversation.
      chats.newChat();

      sender.emit(
        first,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      );
      await sender.close(first);
      await Future<void>.delayed(Duration.zero);

      expect(_userTurns(h.container, first), ['first', 'second']);
      // And it did not drag them back: they are still on the new chat.
      expect(h.container.read(chatSessionsProvider).activeId, isNull);
    });

    test(
      'stopping the turn drops what was queued behind it — Stop means stop',
      () async {
        final sender = _PerChatSender();
        final h = _harness(
          tmp,
          agentInstalled: true,
          updates: const [],
          answering: sender,
        );
        final chats = h.container.read(chatSessionsProvider.notifier);

        unawaited(
          chats.send(network: _credential(), model: 'qwen', message: 'first'),
        );
        await Future<void>.delayed(Duration.zero);
        final id = h.container.read(chatSessionsProvider).activeId!;
        unawaited(
          chats.send(network: _credential(), model: 'qwen', message: 'second'),
        );
        await Future<void>.delayed(Duration.zero);

        chats.stop();
        await Future<void>.delayed(Duration.zero);

        expect(h.container.read(chatSessionsProvider).queuedFor(id), isEmpty);
        expect(_userTurns(h.container, id), ['first']);
      },
    );

    test('can be taken back before it goes out', () async {
      final sender = _PerChatSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [],
        answering: sender,
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'first'),
      );
      await Future<void>.delayed(Duration.zero);
      final id = h.container.read(chatSessionsProvider).activeId!;
      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'oops'),
      );
      await Future<void>.delayed(Duration.zero);

      chats.cancelQueued(id, 0);
      sender.emit(
        id,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      );
      await sender.close(id);
      await Future<void>.delayed(Duration.zero);

      expect(_userTurns(h.container, id), ['first']);
    });
  });

  group('a goal the assistant works on by itself', () {
    /// Let every queued continuation land — the loop hands the next turn off
    /// with `unawaited`, so a single await would only see the first one.
    Future<void> settle() async {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'keeps sending turns until it runs out of the budget it was given',
      () async {
        final h = _harness(
          tmp,
          agentInstalled: true,
          updates: const [
            ChatSendSuccess(
              ChatMessage(
                role: ChatRole.assistant,
                text: 'Still working on it.',
              ),
            ),
          ],
        );
        final chats = h.container.read(chatSessionsProvider.notifier);
        await chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'start here',
        );

        await chats.startGoal(
          objective: 'Get the tests passing',
          maxTurns: 3,
          maxMinutes: 60,
        );
        await settle();

        final chat = h.container
            .read(chatSessionsProvider)
            .conversations
            .single;
        expect(chat.goal?.status, GoalStatus.spent);
        expect(chat.goal?.turnsUsed, 3);
        // Three goal turns on top of the one the user typed.
        expect(_userTurns(h.container, chat.id), hasLength(4));
      },
    );

    test('stops the moment the assistant says the goal is met', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [
          ChatSendSuccess(
            ChatMessage(
              role: ChatRole.assistant,
              text: 'All green.\nGOAL COMPLETE',
            ),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');

      await chats.startGoal(
        objective: 'Get the tests passing',
        maxTurns: 10,
        maxMinutes: 60,
      );
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.goal?.status, GoalStatus.done);
      expect(chat.goal?.turnsUsed, 1);
      expect(_userTurns(h.container, chat.id), hasLength(2));
    });

    test('a failed turn blocks it rather than retrying the same failure ten '
        'times', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [ChatSendFailure('The assistant could not start.')],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');

      await chats.startGoal(
        objective: 'Get the tests passing',
        maxTurns: 10,
        maxMinutes: 60,
      );
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.goal?.status, GoalStatus.blocked);
      expect(chat.goal?.note, 'The assistant could not start.');
      expect(chat.goal?.turnsUsed, 1);
    });

    test('pausing mid-turn stops the loop, and the goal keeps everything it '
        'had', () async {
      final sender = _PerChatSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: const [],
        answering: sender,
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'hi'),
      );
      await settle();
      final id = h.container.read(chatSessionsProvider).activeId!;
      sender.emit(
        id,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'k')),
      );
      await sender.close(id);
      await settle();

      unawaited(
        chats.startGoal(
          objective: 'Get the tests passing',
          maxTurns: 10,
          maxMinutes: 60,
        ),
      );
      await settle();
      // The goal's first turn is in flight; the user changes their mind.
      chats.pauseGoal();
      sender.emit(
        id,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      );
      await sender.close(id);
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.goal?.status, GoalStatus.paused);
      expect(chat.goal?.objective, 'Get the tests passing');
      // One goal turn went out before the pause, and no more after it.
      expect(_userTurns(h.container, chat.id), hasLength(2));
    });
  });

  group('the Auto agent', () {
    ({
      ProviderContainer container,
      _FakeSender hermes,
      _FakeSender codex,
      _FakeClassifier grid,
    })
    autoHarness({String routeTo = 'codex', bool servesAuto = true}) {
      final hermes = _FakeSender(_kOneReply);
      final codex = _FakeSender(_kOneReply);
      final grid = _FakeClassifier(routeTo);
      final container = ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(ChatStore(directory: tmp)),
          chatSenderProvider.overrideWithValue(_FakeSender(_kOneReply)),
          hermesChatSenderProvider.overrideWithValue(hermes),
          codexChatSenderProvider.overrideWithValue(codex),
          agentSessionTitleProvider.overrideWithValue(_FakeAgentTitle(null)),
          mediaOutputsDirProvider.overrideWithValue(
            Directory('${tmp.path}/outputs'),
          ),
          // Two agents installed: with one, Auto has nothing to choose between
          // and short-circuits before the grid is asked.
          hermesPathProvider.overrideWithValue('/bin/hermes'),
          codexPathProvider.overrideWithValue('/bin/codex'),
          claudePathProvider.overrideWithValue(null),
          piPathProvider.overrideWithValue(null),
          gridOverviewProvider.overrideWith((ref) => _overview()),
          gridServesAutoModelProvider.overrideWith((ref) => servesAuto),
          chatTransportProvider.overrideWithValue(grid),
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
          ),
          projectsStoreProvider.overrideWithValue(
            ProjectsStore(file: File('${tmp.path}/projects.json')),
          ),
          selectedNetworkProvider.overrideWith(_FixedNetwork.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(chatScopePrefsProvider).setAgent(kAutoAgentId);
      return (container: container, hermes: hermes, codex: codex, grid: grid);
    }

    test('the agent the grid named is the one that answers', () async {
      final h = autoHarness(routeTo: 'codex');

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(
            network: _credential(),
            model: 'qwen',
            message: 'refactor this module',
          );

      expect(h.codex.history, isNotNull);
      expect(h.hermes.history, isNull);
      // On a grid that serves it, the turn runs on the router model — the one
      // every agent can be pointed at.
      expect(h.codex.model, 'auto');
    });

    test('the chat keeps the model the user picked, not `auto`', () async {
      // The composer is restored from the conversation's model, so writing the
      // router's id there replaces their choice — and it stays replaced after
      // they go back to a named agent.
      final h = autoHarness();

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.model, 'qwen');
      expect((await ChatStore(directory: tmp).loadAll()).single.model, 'qwen');
    });

    test('a turn carrying a picture is never routed', () async {
      // It goes to the grid's chat API whoever is picked, so classifying it
      // spends a relay call and seconds of the turn on an answer thrown away.
      final h = autoHarness();

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(
            network: _credential(),
            model: 'vision',
            message: 'what is this?',
            attachments: [
              MediaAttachment(
                filename: 'pic.png',
                bytes: Uint8List.fromList([1, 2, 3]),
              ),
            ],
          );

      expect(h.grid.calls, 0);
    });

    test('approving a plan stays with the agent that wrote it', () async {
      // The plan lives in that agent's session; handing the execute turn to
      // whoever the classifier likes next asks an agent to carry out a plan it
      // has never seen.
      final h = autoHarness(routeTo: 'codex');
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'refactor this module',
        planFirst: true,
      );
      // The grid changes its mind — the approve turn must not follow it.
      h.grid.reply = 'hermes';
      await chats.approvePlan();

      expect(h.codex.planFirsts, [true, false]);
      expect(h.hermes.history, isNull);
    });

    test(
      'while the grid is choosing, the chat is not waiting on a lane',
      () async {
        // The transcript draws "finishing another chat in this project…" from
        // this fact alone. Routing leaves the turn committed but undispatched —
        // read as "queued", that line went under a chat in a project where
        // nothing else was running, and the user read it as the app doing
        // something it wasn't.
        final h = autoHarness();
        final chats = h.container.read(chatSessionsProvider.notifier);
        final project = h.container
            .read(projectsProvider.notifier)
            .add('${tmp.path}/api');
        chats.newChat(projectId: project.id);
        h.grid.hold();

        final sending = chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'refactor this module',
        );
        await pumpEventQueue();

        final waiting = h.container.read(chatSessionsProvider);
        expect(waiting.sending, isTrue, reason: 'the turn is in flight');
        expect(waiting.laneQueuedIn(waiting.activeId), isFalse);
        expect(waiting.agentRunningIn(waiting.activeId), isFalse);

        h.grid.release();
        await sending;
      },
    );

    test(
      "the previous turn's steps are gone before the grid is even asked",
      () async {
        // The working bubble is on screen from the moment the turn is committed,
        // and routing holds it there for seconds. Left unreset, the new question
        // sat under the last turn's terminal commands — the user reads that as
        // the app running them again, now.
        final h = autoHarness();
        final chats = h.container.read(chatSessionsProvider.notifier);
        await chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'what is a CR-V worth?',
        );
        final id = h.container.read(chatSessionsProvider).activeId!;
        h.container
            .read(agentRunsProvider.notifier)
            .upsertStep(
              id,
              const AgentActivity(
                id: 'step-1',
                kind: AgentActivityKind.command,
                label: 'uv run --with ddgs python3 …',
                status: AgentActivityStatus.done,
              ),
            );
        expect(h.container.read(agentRunProvider(id)).steps, hasLength(1));

        h.grid.hold();
        final sending = chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'open the browser for me',
        );
        await pumpEventQueue();

        expect(
          h.container.read(agentRunProvider(id)).steps,
          isEmpty,
          reason: 'the feed is this turn\'s, and this turn has run nothing yet',
        );
        h.grid.release();
        await sending;
      },
    );

    test('Stop while the grid is still choosing sends nothing', () async {
      // Routing is the one long await between committing the turn and sending
      // it. Stop settles the send; dispatching afterwards would start an agent
      // the user has already stopped.
      final h = autoHarness();
      final chats = h.container.read(chatSessionsProvider.notifier);
      h.grid.hold();

      final sending = chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'refactor this module',
      );
      await Future<void>.delayed(Duration.zero);
      chats.stop();
      h.grid.release();
      await sending;

      expect(h.codex.history, isNull);
      expect(h.hermes.history, isNull);
      expect(h.container.read(chatSessionsProvider).sending, isFalse);
    });
  });
}

const _kOneReply = [
  ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'done')),
];

/// The grid's classifier: names an agent, and can be held mid-call so a test can
/// do something (press Stop) while the turn is still waiting on it.
class _FakeClassifier implements ChatTransport {
  _FakeClassifier(this.reply);

  String reply;
  int calls = 0;
  Completer<void>? _gate;

  /// Make the next call wait until [release].
  void hold() => _gate = Completer<void>();

  void release() => _gate?.complete();

  @override
  Stream<ChatStreamEvent> stream({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async* {
    calls++;
    final gate = _gate;
    if (gate != null) await gate.future;
    yield ChatDelta(reply);
    yield const ChatDone();
  }
}

/// The user's own messages in the chat [id], in order — what actually got sent.
List<String> _userTurns(ProviderContainer container, String id) => [
  for (final m
      in container
          .read(chatSessionsProvider)
          .conversations
          .firstWhere((c) => c.id == id)
          .messages)
    if (m.role == ChatRole.user) m.text,
];
