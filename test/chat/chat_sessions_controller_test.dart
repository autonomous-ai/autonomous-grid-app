import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_resume_point.dart';
import 'package:grid_app/features/chat/logic/chat_approval.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/commands/chat_command.dart';
import 'package:grid_app/features/chat/logic/commands/chat_loop.dart';
import 'package:grid_app/features/chat/logic/commands/chat_compaction.dart';
import 'package:grid_app/features/chat/logic/commands/chat_goal.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/chat_title_writer.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/logic/interrupted_turn.dart';
import 'package:grid_app/features/agents/logic/agent_session_title.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_chat_scope.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/agent_questions.dart';
import 'package:grid_app/features/agents/logic/agent_steering.dart';
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
    String? agentCommand,
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
  final histories = <List<ChatMessage>>[];
  final models = <String>[];
  final attachmentsPerTurn = <List<MediaAttachment>>[];

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
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    histories.add(history);
    models.add(model);
    attachmentsPerTurn.add(attachments);
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
    String? agentCommand,
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
    String? agentCommand,
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

/// An agent whose first turn answers and every turn after it hangs — a stand-in
/// for a `claude -p` that returns once and then sits forever (the log showed one
/// at 286 minutes). [hungCancelled] records that the loop's ceiling really tore
/// the stuck turn down rather than leaving it running behind a frozen loop.
class _HangAfterFirstSender implements ChatSender {
  int calls = 0;
  bool hungCancelled = false;

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
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [
        ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
      ]);
    }
    // Never emits: send()'s future stays pending and, with no update ever, the
    // stall window is the only thing that can end it.
    return StreamController<ChatSendUpdate>(
      onCancel: () => hungCancelled = true,
    ).stream;
  }
}

/// An agent whose first turn answers and whose second turn is a stream the test
/// drives by hand — to prove a loop turn that keeps emitting is left running
/// past the stall window. Whether it was cut off is read from the outcome: a
/// turn stopped mid-stream never delivers its final reply.
class _StreamingLoopSender implements ChatSender {
  int calls = 0;
  StreamController<ChatSendUpdate>? loopTurn;

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
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [
        ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
      ]);
    }
    return (loopTurn = StreamController<ChatSendUpdate>()).stream;
  }
}

/// A fixed selected grid, so approving a plan (which reads the current grid to
/// send the execute turn) never touches the real `~/.grid`.
class _FixedNetwork extends SelectedNetwork {
  @override
  NetworkCredential? build() => _credential();
}

/// A grid that can be dropped mid-test — modelling a background sync emptying
/// the session for a moment, the blip that used to kill a running loop for good.
class _FlippableNetwork extends SelectedNetwork {
  bool dropped = false;

  @override
  NetworkCredential? build() => dropped ? null : _credential();

  void drop() {
    dropped = true;
    ref.invalidateSelf();
  }
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

/// Stands in for the one-shot call that asks a model to name the chat, so no
/// test reaches for a relay. Records what it was shown, since the point of the
/// second naming pass is that it only runs when the first one came back empty.
class _FakeTitleWriter implements ChatTitleWriter {
  _FakeTitleWriter(this.title);

  /// Mutable, so a test can play the case the retry exists for: nothing could
  /// name the chat on its first reply, and something can by its second.
  String? title;
  final asked = <int>[];

  @override
  Future<String?> write(List<ChatMessage> messages) async {
    asked.add(messages.length);
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
  _FakeTitleWriter titleWriter,
})
_harness(
  Directory dir, {
  required List<ChatSendUpdate> updates,
  bool agentInstalled = false,
  String? agentName,
  bool holdAgentName = false,
  String? modelName,
  ChatSender? answering,
  GridOverview? overview,
  ChatTransport? grid,
  Duration? loopTurnStall,
  Duration? loopContinuousGap,
  Duration? loopResumeSettle,
  SelectedNetwork Function()? selectedNetwork,
}) {
  final store = ChatStore(directory: dir);
  final sender = _FakeSender(updates);
  final agent = _FakeSender(updates);
  final agentTitle = _FakeAgentTitle(agentName, held: holdAgentName);
  final titleWriter = _FakeTitleWriter(modelName);
  final container = ProviderContainer(
    overrides: [
      chatStoreProvider.overrideWithValue(store),
      // Shorten the stall window so a test can prove a hung loop turn is stopped
      // — and a working one is left alone — without waiting the full hour.
      if (loopTurnStall != null)
        loopTurnStallProvider.overrideWithValue(loopTurnStall),
      // Shrink the continuous gap so a test can drive back-to-back turns.
      if (loopContinuousGap != null)
        loopContinuousGapProvider.overrideWithValue(loopContinuousGap),
      // Shrink the settle a resumed loop waits, so a test can watch the overdue
      // beat go out without holding the clock for fifteen seconds.
      if (loopResumeSettle != null)
        loopResumeSettleProvider.overrideWithValue(loopResumeSettle),
      // [answering] stands in for whoever replies, for a test that cares about
      // the reply arriving over time rather than about who sent it.
      chatSenderProvider.overrideWithValue(answering ?? sender),
      hermesChatSenderProvider.overrideWithValue(answering ?? agent),
      agentSessionTitleProvider.overrideWithValue(agentTitle),
      chatTitleWriterProvider.overrideWithValue(titleWriter),
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
      // Approving a plan reads the current grid; keep it off the real home. A
      // test can pass its own to model the grid blinking out mid-loop.
      selectedNetworkProvider.overrideWith(
        selectedNetwork ?? _FixedNetwork.new,
      ),
      // What answers the one-shot calls — the goal's evaluator, `/compact`'s
      // summarizer. Absent unless a test cares, so nothing reaches a network.
      if (grid != null) ...[
        chatTransportProvider.overrideWithValue(grid),
        // And something for `resolveOneShotTarget` to resolve *to*: without a
        // text model on the grid there is nobody to ask, and the goal stalls
        // before any verdict is read.
        playgroundModelsProvider.overrideWith(
          (ref) => const [
            PlaygroundModelOption(
              id: 'qwen',
              label: 'qwen',
              modality: PlaygroundModality.text,
            ),
          ],
        ),
      ],
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    store: store,
    sender: sender,
    agent: agent,
    agentTitle: agentTitle,
    titleWriter: titleWriter,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_chat_test');
  });
  // Retried, not just called. ChatStore saves into this directory as turns
  // settle, so a write can land BETWEEN the recursive delete listing the folder
  // and removing it — the delete then fails with "Directory not empty", from a
  // test that had already passed. Intermittent, and only under load.
  tearDown(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await tmp.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

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

  group('a question the assistant asked over the composer', () {
    /// The chat the card is over, with one question outstanding in it.
    Future<({ProviderContainer container, String chatId})> asked(
      Directory dir,
    ) async {
      final h = _harness(
        dir,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'ok'),
          ),
        ],
      );
      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'hi');
      final chatId = h.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .id;
      h.container.read(agentChatScopeProvider.notifier).show(chatId);
      h.container.read(agentQuestionsProvider.notifier).ask(chatId, const [
        AgentQuestion(
          question: 'How often?',
          header: 'Frequency',
          multiSelect: false,
          options: [AgentQuestionOption(label: 'Daily', description: '')],
        ),
      ]);
      return (container: h.container, chatId: chatId);
    }

    test(
      'the answer goes back as the next message — the tool call that asked '
      'was closed by the CLI itself, so there is nothing left to reply to',
      () async {
        final h = await asked(tmp);

        await h.container
            .read(chatSessionsProvider.notifier)
            .answerQuestions('Frequency: Daily');

        expect(_userTurns(h.container, h.chatId).last, 'Frequency: Daily');
      },
    );

    test('answering takes the card down at once, so a queued answer never '
        'leaves the question sitting there unanswered', () async {
      final h = await asked(tmp);

      await h.container
          .read(chatSessionsProvider.notifier)
          .answerQuestions('Frequency: Daily');

      expect(h.container.read(openChatQuestionsProvider), isEmpty);
    });

    test('saying something else instead takes it down too — the conversation '
        'has moved past the decision the card was still offering', () async {
      final h = await asked(tmp);

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'never mind');

      expect(h.container.read(openChatQuestionsProvider), isEmpty);
    });
  });

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
      expect(conv.title, 'Hi');
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

  group('agent turns run side by side', () {
    test('two chats in one project answer at the same time — a question about '
        'a folder must not sit behind a twenty-minute turn in it', () async {
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
      expect(read().agentRunningIn(aId), isTrue);

      // Chat B (tin thế giới) is sent into the same project while A is still
      // generating. It reaches the agent straight away.
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
        isTrue,
        reason: 'the second turn in this project dispatches, it does not queue',
      );
      expect(
        read().runningAgents,
        {aId: 'hermes', bId: 'hermes'},
        reason:
            'each running turn records the agent answering it, which is '
            'what "Working now" names — under Auto it is decided per turn, so '
            'the chat\'s own pick would be a guess',
      );

      // A finishes without disturbing B, which is still going.
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
        read().runningAgents.keys.toSet(),
        {bId},
        reason: 'one finishing releases only itself',
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
      expect(
        s.runningAgents.keys.toSet(),
        isEmpty,
        reason: 'no agent turn left running',
      );
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
        reason: 'another folder entirely — nothing to wait for',
      );
      expect(read().runningAgents.keys.toSet(), {aId, bId});

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
      expect(read().runningAgents.keys.toSet(), isEmpty);
    });

    test(
      'chats outside every project answer together too — the rule is the same '
      'wherever a chat lives',
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
        expect(read().runningAgents.keys.toSet(), {aId, bId});

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

    test('deleting one chat mid-turn leaves the other running — they share a '
        'folder, not a fate', () async {
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
      expect(read().runningAgents.keys.toSet(), {aId, bId});

      // Delete A mid-turn: its send settles, B carries on.
      c.deleteConversation(aId);
      await sentA;
      await pumpEventQueue();
      expect(read().runningAgents.keys.toSet(), {
        bId,
      }, reason: 'A is gone; B never noticed');
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
    });
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

    test('stopChat interrupts a chat the desktop is not looking at, and files '
        'what it had said into that chat — the panel stops a project, and '
        'nobody at a desk with a panel on it is watching the window', () async {
      final answering = _PerChatSender();
      final h = _harness(tmp, updates: const [], answering: answering);
      final c = h.container.read(chatSessionsProvider.notifier);
      ChatSessionsState read() => h.container.read(chatSessionsProvider);

      final sentA = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'explain grids',
      );
      await pumpEventQueue();
      final aId = read().activeId!;
      answering.emit(aId, const ChatSendStreaming('A grid is your private'));
      await pumpEventQueue();

      // The user moves on and starts talking in a second chat.
      c.newChat();
      final sentB = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'and now this',
      );
      await pumpEventQueue();
      final bId = read().activeId!;

      c.stopChat(aId);
      await sentA;

      expect(read().sendingFor(aId), isFalse);
      expect(
        read().sendingFor(bId),
        isTrue,
        reason: 'the chat on screen is left running',
      );
      expect(
        read().activeId,
        bId,
        reason: 'stopping elsewhere never moves the user',
      );
      // The half-written answer belongs to the chat it was streaming into.
      Conversation chat(String id) =>
          read().conversations.firstWhere((c) => c.id == id);
      expect(chat(aId).messages.last.text, 'A grid is your private');
      expect(chat(bId).messages.map((m) => m.role), [ChatRole.user]);

      answering.emit(
        bId,
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'done'),
        ),
      );
      await answering.close(bId);
      await sentB;
    });
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

  test(
    'retry replaces a failed partial answer and resends the original pictured '
    'turn with the newly selected model',
    () async {
      final answering = _ScriptedSender([
        [
          const ChatSendFailure(
            'This model cannot read images.',
            partial: ChatMessage(
              role: ChatRole.assistant,
              text: 'I cannot inspect that picture.',
            ),
          ),
        ],
        [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'It is a mouse.'),
          ),
        ],
      ]);
      final h = _harness(tmp, updates: const [], answering: answering);
      final chats = h.container.read(chatSessionsProvider.notifier);
      final picture = MediaAttachment(
        filename: 'mouse.png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      await chats.send(
        network: _credential(),
        model: 'text-only',
        message: 'What is this?',
        attachments: [picture],
      );
      final failed = h.container.read(chatSessionsProvider);
      final savedPath = failed.active!.messages.first.media.single.path;
      expect(failed.active!.messages, hasLength(2));
      expect(failed.error, 'This model cannot read images.');

      await chats.retry(network: _credential(), model: 'vision-model');

      final retried = h.container.read(chatSessionsProvider);
      expect(answering.calls, 2);
      expect(answering.models, ['text-only', 'vision-model']);
      expect(answering.attachmentsPerTurn.last.single.bytes, picture.bytes);
      expect(answering.histories.last, hasLength(1));
      expect(answering.histories.last.single.media.single.path, savedPath);
      expect(retried.active!.messages, hasLength(2));
      expect(retried.active!.messages.map((message) => message.text), [
        'What is this?',
        'It is a mouse.',
      ]);
      expect(retried.error, isNull);
    },
  );

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
      'Hi',
    );
  });

  test('a chat neither the agent nor a model could name keeps the name taken '
      'from what was typed — nothing is ever blanked', () async {
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
        .send(
          network: _credential(),
          model: 'qwen',
          message: 'help me edit this launch post',
        );
    await pumpEventQueue();

    expect(
      h.container.read(chatSessionsProvider).conversations.single.title,
      'Edit this launch post',
    );
  });

  test('a chat the agent never named is named by a model instead — most chats '
      'are answered by something that names nothing', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      modelName: 'Ngân sách quý 4',
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'qwen', message: 'hi');
    await pumpEventQueue();

    final conv = h.container.read(chatSessionsProvider).conversations.single;
    expect(conv.title, 'Ngân sách quý 4');
    // Both turns of the opening exchange, since the ask alone is the vague half.
    expect(h.titleWriter.asked, [2]);
    expect(
      (await ChatStore(directory: tmp).loadAll()).single.title,
      conv.title,
    );
  });

  test('the name the agent gave its own session is taken as it is, without '
      'spending a request on a name it already has', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      agentName: 'Đọc thư mục dự án',
      modelName: 'Never asked for',
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
      'Đọc thư mục dự án',
    );
    expect(h.titleWriter.asked, isEmpty);
  });

  test('a chat nothing could name yet is named on a later turn, instead of '
      'wearing its first line for good', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(
      network: _credential(),
      model: 'qwen',
      message: 'help me edit this launch post',
    );
    await pumpEventQueue();
    // Neither pass could answer, so the line the user typed still stands.
    expect(
      h.container.read(chatSessionsProvider).conversations.single.title,
      'Edit this launch post',
    );

    // A model can answer by the time the next turn lands.
    h.titleWriter.title = 'Bài đăng ra mắt';
    await controller.send(
      network: _credential(),
      model: 'qwen',
      message: 'shorter please',
    );
    await pumpEventQueue();

    final conv = h.container.read(chatSessionsProvider).conversations.single;
    expect(conv.title, 'Bài đăng ra mắt');
    expect(conv.titleFromModel, isTrue);
    // Asked once per turn while the chat had no name of its own — and the
    // agent, which names a session only off its opening exchange, was not
    // polled a second time.
    expect(h.titleWriter.asked, [2, 4]);
    expect(h.agentTitle.asked, ['sess-1']);
  });

  test(
    'a chat a model has named is left alone by every turn after it',
    () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        modelName: 'Bài đăng ra mắt',
        updates: [
          const ChatSendAgentSession('sess-1'),
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );
      final controller = h.container.read(chatSessionsProvider.notifier);

      await controller.send(network: _credential(), model: 'm', message: 'hi');
      await pumpEventQueue();
      await controller.send(
        network: _credential(),
        model: 'm',
        message: 'more',
      );
      await pumpEventQueue();

      expect(
        h.container.read(chatSessionsProvider).conversations.single.title,
        'Bài đăng ra mắt',
      );
      // Named once. A second ask would spend a request to rename a chat the user
      // has by now read in the rail.
      expect(h.titleWriter.asked, [2]);
    },
  );

  test('the name a model gave survives a restart, so a reloaded chat is not '
      'put back in the queue to be named again', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      modelName: 'Bài đăng ra mắt',
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );

    await h.container
        .read(chatSessionsProvider.notifier)
        .send(network: _credential(), model: 'm', message: 'hi');
    await pumpEventQueue();

    final reloaded = (await ChatStore(directory: tmp).loadAll()).single;
    expect(reloaded.title, 'Bài đăng ra mắt');
    expect(reloaded.titleFromModel, isTrue);
  });

  test('a chat the user named is left alone by both naming passes', () async {
    final h = _harness(
      tmp,
      agentInstalled: true,
      modelName: 'Ngân sách quý 4',
      updates: [
        const ChatSendAgentSession('sess-1'),
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      ],
    );
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'qwen', message: 'hi');
    final id = h.container.read(chatSessionsProvider).conversations.single.id;
    controller.renameConversation(id, 'Kế hoạch tuần');
    await pumpEventQueue();

    expect(
      h.container.read(chatSessionsProvider).conversations.single.title,
      'Kế hoạch tuần',
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
    /// A chat whose every turn stops for want of room, until [thenFinishes]
    /// turns are behind it. The sender repeats its last script once it runs
    /// out, so a run of "ran out of room" replies is one entry long.
    ({ProviderContainer container, _ScriptedSender sender}) cappedHarness({
      required int outOfStepsTurns,
    }) {
      final sender = _ScriptedSender([
        for (var i = 0; i < outOfStepsTurns; i++)
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
        answering: sender,
      );
      return (container: h.container, sender: sender);
    }

    test(
      'carries on by itself, because the person who set a long task going '
      'is the person least likely to be there to press a button (#28)',
      () async {
        final h = cappedHarness(outOfStepsTurns: 1);

        await h.container
            .read(chatSessionsProvider.notifier)
            .send(network: _credential(), model: 'qwen', message: 'do the lot');
        await pumpEventQueue();

        expect(
          h.sender.calls,
          2,
          reason: 'a second turn — a fresh budget — went out unasked',
        );
        final state = h.container.read(chatSessionsProvider);
        expect(
          state.outOfSteps,
          isFalse,
          reason: 'the second turn finished it',
        );
        expect(
          state.conversations.single.messages.last.text,
          'Finished the rest.',
        );
      },
    );

    test('stops after three turns of its own and hands back, rather than '
        'spending someone\'s grid on a task that never converges', () async {
      final h = cappedHarness(outOfStepsTurns: 4);

      await h.container
          .read(chatSessionsProvider.notifier)
          .send(network: _credential(), model: 'qwen', message: 'do the lot');
      await pumpEventQueue();

      expect(
        h.sender.calls,
        1 + kCarryOnTurns,
        reason: 'the turn the user asked for, and three of the app\'s own',
      );
      final state = h.container.read(chatSessionsProvider);
      expect(state.outOfSteps, isTrue, reason: 'the offer is back');
      expect(
        state.carriedOnHere,
        kCarryOnTurns,
        reason: 'the bar says how many turns went on this while nobody watched',
      );
    });

    test('the user pressing Carry on hands out a fresh budget — they have read '
        'where it got to and asked for more', () async {
      final h = cappedHarness(outOfStepsTurns: 4);
      final controller = h.container.read(chatSessionsProvider.notifier);

      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'do the lot',
      );
      await pumpEventQueue();
      await controller.continueTurn();
      await pumpEventQueue();

      expect(h.sender.calls, 1 + kCarryOnTurns + 1);
      final state = h.container.read(chatSessionsProvider);
      expect(state.outOfSteps, isFalse);
      expect(state.carriedOnHere, 0, reason: 'the budget starts over');
    });

    test('a message the user sends clears the budget — the count guards one '
        'instruction running away, not a conversation', () async {
      final h = cappedHarness(outOfStepsTurns: 4);
      final controller = h.container.read(chatSessionsProvider.notifier);

      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'do the lot',
      );
      await pumpEventQueue();
      expect(
        h.container.read(chatSessionsProvider).carriedOnHere,
        kCarryOnTurns,
      );

      await controller.send(
        network: _credential(),
        model: 'qwen',
        message: 'never mind — do this instead',
      );
      await pumpEventQueue();

      expect(h.container.read(chatSessionsProvider).carriedOnHere, 0);
    });

    test(
      'waving the offer away sends nothing — stopping short may be fine',
      () async {
        final h = cappedHarness(outOfStepsTurns: 4);
        final controller = h.container.read(chatSessionsProvider.notifier);

        await controller.send(
          network: _credential(),
          model: 'qwen',
          message: 'do the lot',
        );
        await pumpEventQueue();
        controller.dismissOutOfSteps();
        await pumpEventQueue();

        expect(h.container.read(chatSessionsProvider).outOfSteps, isFalse);
        expect(
          h.sender.calls,
          1 + kCarryOnTurns,
          reason: 'dismissing spends no further turn',
        );
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
      await pumpEventQueue();

      final state = h.container.read(chatSessionsProvider);
      expect(state.outOfSteps, isFalse);
      expect(state.carriedOnHere, 0, reason: 'nothing was carried on');
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
    test('goes into the answer being written, not into a queue behind it — a '
        'correction is worth nothing once the work is done', () async {
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

      // What every agent sender does while its turn runs: leave a way in.
      final steered = <String>[];
      h.container.read(agentSteeringProvider.notifier).offer(id, (text) async {
        steered.add(text);
        return null;
      });

      unawaited(
        chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'just look at the main file',
        ),
      );
      await pumpEventQueue();

      expect(steered, ['just look at the main file']);
      expect(h.container.read(chatSessionsProvider).queuedFor(id), isEmpty);
      // Inside the turn that is running, not above it: a second user bubble over
      // the whole reply would read as a question asked before the agent started,
      // which is the opposite of what happened.
      expect(_userTurns(h.container, id), ['first']);
      expect(
        h.container
            .read(agentRunProvider(id))
            .parts
            .whereType<TurnSaid>()
            .map((part) => part.text),
        ['just look at the main file'],
      );
      // And the chat is still answering the same turn — nothing started a new one.
      expect(h.container.read(chatSessionsProvider).sending, isTrue);

      sender.emit(
        id,
        const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
      );
      await sender.close(id);
      await pumpEventQueue();

      // It lands with the answer it changed, so reopening the chat next week
      // still shows where it was said.
      final reply = h.container
          .read(chatSessionsProvider)
          .conversations
          .firstWhere((c) => c.id == id)
          .messages
          .last;
      expect(reply.role, ChatRole.assistant);
      expect(reply.parts.whereType<TurnSaid>().map((part) => part.text), [
        'just look at the main file',
      ]);
    });

    test('a turn that dies before saying anything still keeps what the user '
        'said into it', () async {
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
      h.container
          .read(agentSteeringProvider.notifier)
          .offer(id, (text) async => null);

      unawaited(
        chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'and quickly',
        ),
      );
      await pumpEventQueue();

      sender.emit(id, const ChatSendFailure('Claude Code stopped.'));
      await sender.close(id);
      await pumpEventQueue();

      final kept = h.container
          .read(chatSessionsProvider)
          .conversations
          .firstWhere((c) => c.id == id)
          .messages
          .last;
      expect(
        kept.parts.whereType<TurnSaid>().map((part) => part.text),
        ['and quickly'],
        reason: 'it lives in the timeline and nowhere else',
      );
      expect(h.container.read(chatSessionsProvider).error, isNotNull);
    });

    test('waits in the queue when the agent will not take it, so a refused '
        'message is never lost', () async {
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
      h.container
          .read(agentSteeringProvider.notifier)
          .offer(id, (text) async => 'The turn had already finished.');

      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'second'),
      );
      await pumpEventQueue();

      expect(
        h.container.read(chatSessionsProvider).queuedFor(id).single.text,
        'second',
      );
      expect(_userTurns(h.container, id), ['first']);
    });

    test('is queued the moment the turn lets go of the channel, so it goes out '
        'as the next turn instead of vanishing', () async {
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
      final steering = h.container.read(agentSteeringProvider.notifier);
      steering.offer(id, (text) async => null);
      steering.withdraw(id);

      unawaited(
        chats.send(network: _credential(), model: 'qwen', message: 'second'),
      );
      await pumpEventQueue();

      expect(
        h.container.read(chatSessionsProvider).queuedFor(id).single.text,
        'second',
      );
    });

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

  group('/clear starts a new chat where the user is standing (issue #13)', () {
    test('inside a project, the fresh chat stays in that project — the folder '
        'is the whole reason they opened a chat there', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      final project = h.container
          .read(projectsProvider.notifier)
          .add('${tmp.path}/my-notes');
      chats.newChat(projectId: project.id);
      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'what changed?',
      );

      chats.runCommand((command: ChatCommand.clear, argument: ''));

      final state = h.container.read(chatSessionsProvider);
      expect(state.activeId, isNull);
      expect(state.draftProjectId, project.id);
      // The chat it started from is still there: /clear starts something new,
      // it does not throw the conversation away.
      expect(state.conversations, hasLength(1));
    });

    test('outside a project it lands in the chat list, with no project '
        'invented for it', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hello');

      chats.runCommand((command: ChatCommand.clear, argument: ''));

      final state = h.container.read(chatSessionsProvider);
      expect(state.activeId, isNull);
      expect(state.draftProjectId, isNull);
      expect(state.conversations, hasLength(1));
    });
  });

  group('/goal', () {
    /// Let the loop's queued continuations land — each turn hands the next off
    /// with `unawaited`, so one await would only see the first.
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('setting a goal sends the condition straight out — a goal that waits '
        'for you to type something is a note to yourself', () async {
      final grid = _FakeClassifier('MET\nAll green.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'done'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');

      await chats.runCommand((
        command: ChatCommand.goal,
        argument: 'the tests pass',
      ));
      await settle();

      final id = h.container.read(chatSessionsProvider).conversations.single.id;
      expect(_userTurns(h.container, id), contains('the tests pass'));
    });

    test(
      '/goal typed into a blank composer starts the chat rather than '
      'refusing — as far as anything on screen says the user is in one '
      'already, and a chat is only saved once something is said in it',
      () async {
        final grid = _FakeClassifier('MET\nAll green.');
        final h = _harness(
          tmp,
          agentInstalled: true,
          grid: grid,
          updates: [
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'done'),
            ),
          ],
        );
        final chats = h.container.read(chatSessionsProvider.notifier);

        final outcome = await chats.runCommand((
          command: ChatCommand.goal,
          argument: 'the tests pass',
        ), model: 'qwen');
        await settle();

        expect(outcome, isNull);
        final session = h.container.read(chatSessionsProvider);
        final chat = session.conversations.single;
        // Started, left open in front of the user, on the model the picker was
        // showing — and already working on the condition.
        expect(session.activeId, chat.id);
        expect(chat.model, 'qwen');
        expect(chat.goal?.condition, 'the tests pass');
        expect(_userTurns(h.container, chat.id), contains('the tests pass'));
      },
    );

    test('a goal that is refused starts nothing, so a mistyped condition '
        'leaves no empty chat behind in the sidebar', () async {
      final h = _harness(tmp, updates: const []);
      final chats = h.container.read(chatSessionsProvider.notifier);

      final outcome = await chats.runCommand((
        command: ChatCommand.goal,
        argument: 'x' * (kMaxGoalCondition + 1),
      ), model: 'qwen');

      expect(outcome?.failed, isTrue);
      expect(h.container.read(chatSessionsProvider).conversations, isEmpty);
    });

    test(
      'a MET verdict ends it, and the bar says met rather than stopped',
      () async {
        final grid = _FakeClassifier('MET\nAll six tests pass.');
        final h = _harness(
          tmp,
          agentInstalled: true,
          grid: grid,
          updates: [
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'done'),
            ),
          ],
        );
        final chats = h.container.read(chatSessionsProvider.notifier);
        await chats.send(network: _credential(), model: 'qwen', message: 'hi');
        await chats.runCommand((
          command: ChatCommand.goal,
          argument: 'the tests pass',
        ));
        await settle();

        final goal = h.container
            .read(chatSessionsProvider)
            .conversations
            .single
            .goal;
        expect(goal?.status, GoalStatus.met);
        expect(goal?.reason, 'All six tests pass.');
        expect(goal?.turnsEvaluated, 1);
        // And where it ended, so "Goal met" is drawn in the transcript at the
        // turn it was met on rather than pinned over the composer until
        // somebody closes it.
        expect(
          goal?.endedAfter,
          h.container
              .read(chatSessionsProvider)
              .conversations
              .single
              .messages
              .length,
        );
      },
    );

    test('/goal clear stops it and names the condition back, so "cleared" is '
        'never confused with "nothing was set"', () async {
      final grid = _FakeClassifier('NOT_YET\nTwo still fail.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'working'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await chats.runCommand((
        command: ChatCommand.goal,
        argument: 'the tests pass',
      ));
      await settle();

      final outcome = await chats.runCommand((
        command: ChatCommand.goal,
        argument: 'clear',
      ));

      expect(outcome?.message, contains('the tests pass'));
      expect(outcome?.failed, isFalse);
      expect(
        h.container.read(chatSessionsProvider).conversations.single.goal,
        isNull,
      );
    });

    test('/clear ends the goal on the chat being left, so it cannot go on '
        'firing turns into a conversation the user walked away from', () async {
      final grid = _FakeClassifier('NOT_YET\nStill going.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'working'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await chats.runCommand((
        command: ChatCommand.goal,
        argument: 'the tests pass',
      ));
      await settle();

      await chats.runCommand((command: ChatCommand.clear, argument: ''));
      await settle();

      final left = h.container.read(chatSessionsProvider).conversations.single;
      expect(left.goal, isNull);
    });
  });

  group('/loop', () {
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('/loop typed into a blank composer starts the chat too, and its '
        'first run goes out in it', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'still building'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ), model: 'qwen');
      await settle();

      final session = h.container.read(chatSessionsProvider);
      final chat = session.conversations.single;
      expect(session.activeId, chat.id);
      expect(chat.model, 'qwen');
      expect(chat.loop?.prompt, 'check the deploy');
      expect(_userTurns(h.container, chat.id), contains('check the deploy'));
      // Leave no timer running behind the test.
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('an iteration that says the job is done ends the loop, which is the '
        'only way a finished job ever stopped itself', () async {
      final grid = _FakeClassifier('30\nNothing is pending.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(
              role: ChatRole.assistant,
              text:
                  'The deploy finished and the smoke tests passed.\n\n'
                  '```grid-loop\n'
                  '{"stop": true, "why": "the deploy finished"}\n'
                  '```',
            ),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'check the deploy',
      ), model: 'qwen');
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.loop?.status, LoopStatus.finished);
      expect(chat.loop?.pacing, 'the deploy finished');
      expect(chat.loop?.iterations, 1);
      // Ended, not paused by the user: the two read differently on the bar.
      expect(loopBarLabel(chat.loop!, DateTime.now()), startsWith('Finished:'));
    });

    test('the gap the iteration named is the one waited, and the second model '
        'is never asked — the one that did the work sets the pace', () async {
      final grid = _FakeClassifier('30\nNothing is pending.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(
              role: ChatRole.assistant,
              text:
                  'Still building.\n\n'
                  '```grid-loop\n'
                  '{"next": "45m", "why": "the build has 40 minutes left"}\n'
                  '```',
            ),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'check the deploy',
      ), model: 'qwen');
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.loop?.pacing, 'the build has 40 minutes left');
      expect(
        chat.loop!.nextAt.difference(DateTime.now()).inMinutes,
        greaterThan(40),
      );
      expect(
        grid.calls,
        0,
        reason: 'the pacer is the fallback now, not the path',
      );
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a quiet iteration is counted rather than repeated, so a night of '
        '"nothing yet" reads as a number and not forty answers', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(
              role: ChatRole.assistant,
              text:
                  'Nothing has moved.\n\n'
                  '```grid-loop\n{"quiet": true, "next": "1h"}\n```',
            ),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'check the deploy',
      ), model: 'qwen');
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.loop?.quietStreak, 1);
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test("the app's own instruction and the block it asked for are both taken "
        'back out of the transcript — the user reads the answer, and the next '
        'beat carries the question once, not twice', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(
              role: ChatRole.assistant,
              text:
                  'Still building.\n\n'
                  '```grid-loop\n{"next": "45m"}\n```',
            ),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'check the deploy',
      ), model: 'qwen');
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(_userTurns(h.container, chat.id), ['check the deploy']);
      expect(chat.messages.last.text, 'Still building.');
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a loop that stops records where in the transcript it stopped, so '
        'the line saying so lands on that turn and not at the bottom of '
        'whatever is said next', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'still building'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ));
      await settle();
      final before = h.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .messages
          .length;

      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.loop?.endedAfter, before);
      // Said again later does not move it: it stopped where it stopped.
      await chats.send(network: _credential(), model: 'qwen', message: 'more');
      await settle();
      expect(
        h.container
            .read(chatSessionsProvider)
            .conversations
            .single
            .loop
            ?.endedAfter,
        before,
      );
    });

    test('the first run goes out at once — a loop that sits silent for five '
        'minutes after you set it reads as broken', () async {
      final grid = _FakeClassifier('30\nNothing is pending.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'still building'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ));
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(_userTurns(h.container, chat.id), contains('check the deploy'));
      expect(chat.loop?.interval, const Duration(minutes: 5));
      expect(chat.loop?.iterations, 1);
      expect(chat.loop?.isRunning, isTrue);

      // Leave nothing armed behind the test.
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    /// A chat left on disk exactly as an app that was closed mid-loop leaves
    /// one: a running loop, its next beat [dueIn] from now (negative = overdue),
    /// and a transcript ending in the prompt whose answer never arrived.
    void writeInterruptedLoop({
      required Duration dueIn,
      Duration ranFor = const Duration(hours: 1),
    }) {
      final now = DateTime.now();
      String at(Duration ago) => now.subtract(ago).toUtc().toIso8601String();
      File('${tmp.path}/1787020138395674.json').writeAsStringSync('''
{"id":"1787020138395674","title":"Building","model":"qwen",
 "createdAt":"${at(ranFor)}","updatedAt":"${at(const Duration(minutes: 30))}",
 "messages":[{"role":"user","text":"keep building"}],
 "loop":{"prompt":"keep building","intervalSeconds":300,
  "startedAt":"${at(ranFor)}",
  "nextAt":"${now.add(dueIn).toUtc().toIso8601String()}",
  "status":"running","iterations":1}}
''');
    }

    test('a loop still running when the app closed picks itself back up and '
        'carries on counting — a restart used to end it, and setting it up '
        'again was a new loop that re-did the work from zero', () async {
      // 2026-08-18 in the log: the app was rebuilt mid-turn, the loop died with
      // it, and `/loop` typed again sent the same prompt over the top of what
      // the killed turn had already half done.
      writeInterruptedLoop(dueIn: const Duration(minutes: -3));
      final h = _harness(
        tmp,
        agentInstalled: true,
        loopResumeSettle: const Duration(milliseconds: 10),
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'carried on'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.restored;
      // Poll real time: the settle has to actually elapse before the overdue
      // beat goes out.
      for (var i = 0; i < 100 && h.agent.history == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(
        _userTurns(h.container, chat.id).where((t) => t == 'keep building'),
        hasLength(2),
        reason: 'the resumed beat asks again, which is what a loop is',
      );
      expect(
        chat.loop?.iterations,
        2,
        reason: 'it counts on from where it was rather than starting over',
      );
      // And the turn the restart killed is closed off, so what the agent reads
      // is "that one was interrupted" rather than a prompt nobody answered.
      expect(
        h.agent.history?.map((m) => m.text),
        contains(kInterruptedTurnNote),
      );

      // Leave nothing armed behind the test.
      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a loop whose seven days ran out while the app was closed comes back '
        'expired instead of getting one more free turn', () async {
      writeInterruptedLoop(
        dueIn: const Duration(minutes: -3),
        ranFor: const Duration(days: 8),
      );
      final h = _harness(
        tmp,
        agentInstalled: true,
        loopResumeSettle: const Duration(milliseconds: 10),
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'carried on'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.restored;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.loop?.status, LoopStatus.expired);
      expect(h.agent.history, isNull, reason: 'no turn went out');
    });

    test(
      'a self-paced loop asks how long to wait and shows the reason',
      () async {
        final grid = _FakeClassifier('25\nThe PR has gone quiet.');
        final h = _harness(
          tmp,
          agentInstalled: true,
          grid: grid,
          updates: [
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'no new comments'),
            ),
          ],
        );
        final chats = h.container.read(chatSessionsProvider.notifier);
        await chats.send(network: _credential(), model: 'qwen', message: 'hi');

        await chats.runCommand((
          command: ChatCommand.loop,
          argument: 'watch the PR',
        ));
        await settle();

        final loop = h.container
            .read(chatSessionsProvider)
            .conversations
            .single
            .loop;
        expect(loop?.isSelfPaced, isTrue);
        expect(loop?.pacing, 'The PR has gone quiet.');

        await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
      },
    );

    test(
      'a turn that goes silent is treated as hung and stopped, so the loop '
      'keeps its cadence instead of freezing overnight on one stuck turn',
      () async {
        // The bug: an agent turn hung for 4h46m and, because the next beat is only
        // armed once the current turn returns, the whole loop sat frozen — "run
        // all night" stopped dead after one iteration, with no log to say why.
        final sender = _HangAfterFirstSender();
        final h = _harness(
          tmp,
          agentInstalled: true,
          answering: sender,
          loopTurnStall: const Duration(milliseconds: 100),
          updates: const [],
        );
        final chats = h.container.read(chatSessionsProvider.notifier);
        // Turn one answers and creates the chat.
        await chats.send(network: _credential(), model: 'qwen', message: 'hi');
        await settle();

        // The loop's first iteration goes out to a turn that emits nothing, ever.
        await chats.runCommand((
          command: ChatCommand.loop,
          argument: '5m check the deploy',
        ));

        // Poll real time: the 100ms stall window has to actually elapse.
        for (var i = 0; i < 50 && !sender.hungCancelled; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await settle();

        final chat = h.container
            .read(chatSessionsProvider)
            .conversations
            .single;
        expect(
          sender.calls,
          2,
          reason: 'the setup turn, then the loop iteration',
        );
        expect(
          sender.hungCancelled,
          isTrue,
          reason: 'the hung turn was stopped',
        );
        expect(
          h.container.read(chatSessionsProvider).sendingFor(chat.id),
          isFalse,
          reason: 'the chat is idle again, not stuck answering forever',
        );
        expect(chat.loop?.iterations, 1, reason: 'the next beat was scheduled');
        expect(chat.loop?.isRunning, isTrue);

        await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
      },
    );

    test('closing the app on a running beat leaves the loop running, so the '
        'next launch picks it up instead of ending an overnight job', () async {
      final sender = _StreamingLoopSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        answering: sender,
        updates: const [],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await settle();

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ));
      await settle();
      final id = h.container.read(chatSessionsProvider).conversations.single.id;
      sender.loopTurn!.add(const ChatSendStreaming('half an answer'));
      await settle();

      // What quitting does to a beat in flight: the window's teardown stops
      // every chat that is answering. On 2026-08-19 the loop was `stopped` on
      // disk the same second a beat was torn down this way and never resumed
      // again — while the launches that killed the app outright, leaving the
      // file saying `running`, all came back.
      chats.stopChat(id);
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(
        chat.loop?.isRunning,
        isTrue,
        reason: 'a torn-down beat is not the user ending the loop',
      );
      expect(
        (await h.store.loadAll()).single.loop?.isRunning,
        isTrue,
        reason: 'and the file is what the next launch resumes from',
      );

      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a turn that keeps streaming is left alone past the stall window — a '
        'long turn that is working is not a hang', () async {
      final sender = _StreamingLoopSender();
      final h = _harness(
        tmp,
        agentInstalled: true,
        answering: sender,
        loopTurnStall: const Duration(milliseconds: 300),
        updates: const [],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await settle();

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ));

      // Keep the turn visibly alive: a chunk every 100ms — under the 300ms
      // window, so it never looks silent — for ~700ms, well past the window,
      // before it finishes cleanly.
      final deadline = DateTime.now().add(const Duration(milliseconds: 700));
      while (DateTime.now().isBefore(deadline)) {
        final turn = sender.loopTurn;
        if (turn != null && !turn.isClosed) {
          turn.add(const ChatSendStreaming('working…'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      sender.loopTurn!.add(
        const ChatSendSuccess(
          ChatMessage(role: ChatRole.assistant, text: 'done'),
        ),
      );
      await sender.loopTurn!.close();
      await settle();

      final chat = h.container.read(chatSessionsProvider).conversations.single;
      // Its final reply landed: the turn ran ~700ms, well past the 300ms window,
      // and was never cut off — a turn stopped mid-stream never delivers 'done'.
      expect(
        _assistantTurns(h.container, chat.id),
        contains('done'),
        reason: 'a streaming turn is left to finish, not treated as hung',
      );
      expect(chat.loop?.iterations, 1, reason: 'the next beat was scheduled');
      expect(chat.loop?.isRunning, isTrue);

      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a continuous loop runs turns back-to-back — the "keep building this '
        'project, never stop" a full-day run needs', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        loopContinuousGap: const Duration(milliseconds: 20),
        updates: const [
          ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'did a bit'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await settle();

      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'continuous keep improving the project',
      ));

      // Let several back-to-back iterations run (a 20ms settle between each).
      ChatLoop? loop;
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        loop = h.container.read(chatSessionsProvider).conversations.single.loop;
        if ((loop?.iterations ?? 0) >= 3) break;
      }

      expect(loop?.isContinuous, isTrue);
      expect(
        loop?.iterations,
        greaterThanOrEqualTo(3),
        reason: 'turns fire back-to-back, not on a clock',
      );
      expect(loop?.isRunning, isTrue, reason: 'it never stops on its own');

      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('a grid that blinks out mid-loop does not kill it — a momentary null '
        'grid retries instead of stopping for good', () async {
      final net = _FlippableNetwork();
      final h = _harness(
        tmp,
        agentInstalled: true,
        loopContinuousGap: const Duration(milliseconds: 20),
        selectedNetwork: () => net,
        updates: const [
          ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'ok')),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await settle();
      await chats.runCommand((
        command: ChatCommand.loop,
        argument: 'continuous keep improving',
      ));

      // Let it run, then drop the grid the way a background sync would.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      net.drop();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final loop = h.container
          .read(chatSessionsProvider)
          .conversations
          .single
          .loop;
      expect(
        loop?.isRunning,
        isTrue,
        reason: 'a momentary null grid retries; it does not stop the loop',
      );

      await chats.runCommand((command: ChatCommand.loop, argument: 'stop'));
    });

    test('/loop with nothing to run says what to type instead of starting a '
        'loop about nothing', () async {
      final h = _harness(tmp, agentInstalled: true, updates: const []);
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');

      final outcome = await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m',
      ));

      expect(outcome?.failed, isTrue);
      expect(outcome?.message, contains('/loop 5m'));
      expect(
        h.container.read(chatSessionsProvider).conversations.single.loop,
        isNull,
      );
    });

    test('/clear stops the loop on the chat being left, so nothing goes on '
        'repeating into a conversation nobody is reading', () async {
      final grid = _FakeClassifier('30\nQuiet.');
      final h = _harness(
        tmp,
        agentInstalled: true,
        grid: grid,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'ok'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(network: _credential(), model: 'qwen', message: 'hi');
      await chats.runCommand((
        command: ChatCommand.loop,
        argument: '5m check the deploy',
      ));
      await settle();

      await chats.runCommand((command: ChatCommand.clear, argument: ''));
      await settle();

      final left = h.container.read(chatSessionsProvider).conversations.single;
      expect(left.loop?.isRunning, isFalse);
    });
  });

  group('/compact', () {
    test('after compacting, the turn carries the summary in place of what it '
        'covers — and the chat itself still holds every message', () async {
      final h = _harness(
        tmp,
        agentInstalled: true,
        updates: [
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'a'),
          ),
        ],
      );
      final chats = h.container.read(chatSessionsProvider.notifier);
      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'fix the parser',
      );
      final id = h.container.read(chatSessionsProvider).activeId!;

      // Stand in for the summarizer: the model call is exercised by
      // `chat_compaction_test.dart`; what matters here is what a turn sends
      // once a compaction exists.
      final chat = h.container.read(chatSessionsProvider).conversations.single;
      expect(chat.messages, hasLength(2));
      final compacted = chat.copyWith(
        compaction: ChatCompaction(
          summary: 'we agreed to rewrite the parser',
          through: 2,
          at: DateTime.now(),
        ),
      );
      // Through the app's own store, not a second one over the same folder:
      // writes are queued per chat and drained in order *within* a store, so
      // two of them racing over one file is a hazard only a test can build.
      final store = h.container.read(chatStoreProvider);
      store.save(compacted);
      // The write is off this isolate now, so the reload has to wait for it —
      // in the app nothing does, which is the point of it.
      await store.settled;
      await chats.reloadFromDisk();

      await chats.send(
        network: _credential(),
        model: 'qwen',
        message: 'carry on',
        into: id,
      );

      final sent = h.agent.history!;
      expect(sent.first.text, contains('we agreed to rewrite the parser'));
      expect(sent.map((m) => m.text), isNot(contains('fix the parser')));
      // Nothing was thrown away: the transcript still reads in full.
      final kept = h.container.read(chatSessionsProvider).conversations.single;
      expect(kept.messages.first.text, 'fix the parser');
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
      'retrying a failed continuation stays with its original agent',
      () async {
        final codex = _ScriptedSender([
          [
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'The plan.'),
            ),
          ],
          [const ChatSendFailure('Codex stopped.')],
          [
            const ChatSendSuccess(
              ChatMessage(role: ChatRole.assistant, text: 'Implemented.'),
            ),
          ],
        ]);
        final hermes = _FakeSender(_kOneReply);
        final grid = _FakeClassifier('codex');
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
            hermesPathProvider.overrideWithValue('/bin/hermes'),
            codexPathProvider.overrideWithValue('/bin/codex'),
            claudePathProvider.overrideWithValue(null),
            gridOverviewProvider.overrideWith((ref) => _overview()),
            gridServesAutoModelProvider.overrideWith((ref) => true),
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
        final chats = container.read(chatSessionsProvider.notifier);

        await chats.send(
          network: _credential(),
          model: 'qwen',
          message: 'refactor this module',
          planFirst: true,
        );
        grid.reply = 'hermes';
        await chats.approvePlan();
        expect(container.read(chatSessionsProvider).error, 'Codex stopped.');

        await chats.retry(network: _credential(), model: 'qwen');

        expect(codex.calls, 3);
        expect(hermes.history, isNull);
        expect(grid.calls, 1, reason: 'the continuation is not routed again');
        expect(container.read(chatSessionsProvider).error, isNull);
      },
    );

    test('while the grid is choosing, the turn is in flight but no agent is '
        'running yet', () async {
      // The two are not the same, and the transcript draws different things
      // from them: routing leaves the turn committed and sending, with no
      // agent to show steps for, so the bubble says "Thinking…" rather than
      // opening an empty activity feed.
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
      expect(waiting.agentRunningIn(waiting.activeId), isFalse);

      h.grid.release();
      await sending;
    });

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
    String? conversationId,
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

List<String> _assistantTurns(ProviderContainer container, String id) => [
  for (final m
      in container
          .read(chatSessionsProvider)
          .conversations
          .firstWhere((c) => c.id == id)
          .messages)
    if (m.role == ChatRole.assistant) m.text,
];
