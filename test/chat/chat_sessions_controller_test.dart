import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/agent/common/agent_session_title.dart';
import 'package:grid_app/features/agent/codex/codex_tool.dart';
import 'package:grid_app/features/agent/hermes/hermes_chat_sender.dart';
import 'package:grid_app/features/agent/hermes/hermes_tool.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
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
  }) {
    this.history = history;
    this.model = model;
    this.modality = modality;
    this.attachments = attachments;
    this.workdir = workdir;
    planFirsts.add(planFirst);
    return Stream.fromIterable(updates);
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
      // answers a plain text turn. Codex is pinned absent so the real machine's
      // PATH (which may have codex installed) can't leak in and change routing.
      hermesPathProvider.overrideWithValue(
        agentInstalled ? '/bin/hermes' : null,
      ),
      codexPathProvider.overrideWithValue(null),
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
      final reloaded = ChatStore(directory: tmp).loadAll();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.messages.last.text, 'hi back');
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

  group('agent turns are serialized', () {
    test('a second agent turn waits for the first instead of running at once — '
        'the local agent has one session and one permission focus, and two at '
        'once left one chat hung on a permission the other had cleared', () async {
      final answering = _PerChatSender();
      final h = _harness(
        tmp,
        updates: const [],
        agentInstalled: true,
        answering: answering,
      );
      final c = h.container.read(chatSessionsProvider.notifier);
      ChatSessionsState read() => h.container.read(chatSessionsProvider);

      // Chat A (giá vàng) starts on the agent.
      final sentA = c.send(
        network: _credential(),
        model: 'qwen',
        message: 'giá vàng hôm nay',
      );
      await pumpEventQueue();
      final aId = read().activeId!;
      expect(answering.controllers.containsKey(aId), isTrue);
      expect(read().runningAgentId, aId, reason: 'A holds the agent slot');

      // Chat B (tin thế giới) is sent while A is still generating. It must NOT
      // reach the agent yet — it waits in the queue, showing its own busy state.
      c.newChat();
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
        reason: 'the second agent turn is queued, not dispatched',
      );
      expect(read().sendingFor(aId), isTrue);
      expect(
        read().sendingFor(bId),
        isTrue,
        reason: 'B waits in its busy state',
      );
      expect(
        read().runningAgentId,
        aId,
        reason:
            'A still owns the slot while B waits — B must not borrow its feed',
      );

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
        reason: 'B dispatches once the slot frees',
      );
      expect(read().runningAgentId, bId, reason: 'the slot passes to B');

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
      expect(s.runningAgentId, isNull, reason: 'no agent turn left running');
      final a = s.conversations.firstWhere((x) => x.id == aId);
      final b = s.conversations.firstWhere((x) => x.id == bId);
      expect(a.messages.last.text, 'giá vàng: ...');
      expect(b.messages.last.text, 'tin thế giới: ...');
    });

    test(
      'deleting the chat holding the agent slot lets the queued one run — '
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
        expect(answering.controllers.containsKey(bId), isFalse);

        // Delete A while it holds the slot: B must not wait forever.
        c.deleteConversation(aId);
        await sentA;
        await pumpEventQueue();
        expect(
          answering.controllers.containsKey(bId),
          isTrue,
          reason: 'B runs once A releases the slot',
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
        ChatStore(directory: tmp).loadAll().single.messages.last.text,
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

      final reloaded = ChatStore(directory: tmp).loadAll();
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
    final reloaded = ChatStore(directory: tmp).loadAll().single;
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
    expect(ChatStore(directory: tmp).loadAll(), isEmpty);
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

    final state = container.read(chatSessionsProvider);
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
    final reloaded = ChatStore(directory: tmp).loadAll().single;
    expect(reloaded.projectId, project.id);
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
      expect(ChatStore(directory: tmp).loadAll().single.title, conv.title);
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
    expect(ChatStore(directory: tmp).loadAll().single.title, conv.title);
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
    expect(ChatStore(directory: tmp).loadAll().single.title, 'Ngân sách quý 4');
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

    expect(store.loadAll().single.titleLocked, isTrue);
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
        ChatStore(directory: tmp).loadAll().single.model,
        'deepreinforce-ai/ornith-1.0-35b',
      );
    });

    test('is a no-op for a not-yet-saved compose — nothing to persist yet', () {
      final h = _harness(tmp, updates: const []);
      final controller = h.container.read(chatSessionsProvider.notifier);
      controller.newChat();

      controller.setActiveModel('ornith-35b');

      expect(h.container.read(chatSessionsProvider).active, isNull);
      expect(ChatStore(directory: tmp).loadAll(), isEmpty);
    });
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
}
