import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_chat_sender.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/pi_tool.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/panel/logic/panel_controller.dart';
import 'package:grid_app/features/panel/logic/panel_firmware_updater.dart';
import 'package:grid_app/features/panel/logic/panel_turn_mirror.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/media_outputs.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/api/stt_client.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_resume_point.dart';
import 'package:grid_app/infrastructure/panel/panel_audio.dart';
import 'package:grid_app/infrastructure/panel/panel_firmware.dart';
import 'package:grid_app/infrastructure/panel/panel_firmware_provider.dart';
import 'package:grid_app/infrastructure/panel/panel_frame.dart';
import 'package:grid_app/infrastructure/panel/panel_link.dart';
import 'package:grid_app/infrastructure/panel/panel_link_provider.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/shared/app_info.dart';

import 'panel_firmware_test.dart' show espAppImage;

/// A transport backed by two lists instead of a cable — the same fake
/// `panel_link_test.dart` drives the framing with, so the controller is
/// exercised over the real codec and never over a stub of it.
class _FakeTransport implements PanelTransport {
  final _in = StreamController<List<int>>();
  final sent = <List<int>>[];

  @override
  Stream<List<int>> get incoming => _in.stream;

  @override
  void send(List<int> bytes) => sent.add(bytes);

  @override
  Future<void> close() => _in.close();

  /// Deliver bytes as if the driver had just returned them.
  void deliver(String json) => _in.add(encodePanelJson(json));

  /// Deliver one chunk of a voice capture, on the frame type audio travels on.
  void deliverAudio(List<int> pcm) =>
      _in.add(encodePanelFrame(PanelFrameType.pcm, pcm));

  /// Everything the app has said, decoded back through the real framing.
  List<PanelFrame> get frames {
    final decoder = PanelFrameDecoder();
    return [for (final chunk in sent) ...decoder.feed(chunk)];
  }

  /// The control messages only — a firmware image on the same wire is bytes,
  /// not JSON, and decoding it as JSON would fail on the first slice.
  List<Map<String, Object?>> get replies => [
    for (final frame in frames)
      if (frame.type == PanelFrameType.json)
        jsonDecode(frame.text) as Map<String, Object?>,
  ];

  /// The firmware slices, in the order they went out.
  List<Uint8List> get imageFrames => [
    for (final frame in frames)
      if (frame.type == PanelFrameType.firmware) frame.payload,
  ];
}

/// An [SttClient] that answers with whatever the test says, and keeps the clip
/// it was handed — the file itself is deleted the moment the call returns.
class _FakeStt implements SttClient {
  _FakeStt(this._result);

  final SttResult _result;

  /// The WAV the panel's audio was written into.
  Uint8List? clip;
  String? lang;

  @override
  Future<SttResult> transcribe({
    required String audioPath,
    required String lang,
  }) async {
    clip = File(audioPath).readAsBytesSync();
    this.lang = lang;
    return _result;
  }
}

Conversation _chat({
  required String id,
  required String projectId,
  required DateTime at,
  List<ChatMessage> messages = const [],
  bool pinned = false,
  DateTime? archivedAt,
}) => Conversation(
  id: id,
  title: 'A chat',
  model: 'qwen',
  createdAt: at,
  updatedAt: at,
  messages: messages,
  projectId: projectId,
  pinned: pinned,
  archivedAt: archivedAt,
);

ChatMessage _said(String text) =>
    ChatMessage(role: ChatRole.assistant, text: text);

const _project = Project(id: 'p-1', name: 'grid-app', path: '/tmp/grid-app');

/// A grid that exists without a relay behind it — enough for a turn to be
/// dispatched, and nothing that reaches the network.
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

/// A selected grid that never touches the real `~/.grid` — [grid] is what the
/// app sees, and null stands for a computer with no grid set up at all.
class _PickedNetwork extends SelectedNetwork {
  _PickedNetwork(this.grid);

  final NetworkCredential? grid;

  @override
  NetworkCredential? build() => grid;
}

/// An agent whose turn stays open until the test ends it — so the panel can be
/// watched mid-turn, which is the whole point of pushing turn state.
class _HeldTurn implements ChatSender {
  final _updates = StreamController<ChatSendUpdate>();

  /// What the app asked it to answer, and with what.
  List<ChatMessage>? history;
  String? model;
  String? workdir;

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
    this.workdir = workdir;
    return _updates.stream;
  }

  /// Land the reply and end the turn.
  Future<void> answer(String text) async {
    _updates.add(
      ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: text)),
    );
    await _updates.close();
  }

  /// End the turn with a failure instead.
  Future<void> fail(String error) async {
    _updates.add(ChatSendFailure(error));
    await _updates.close();
  }
}

/// One step in a turn's timeline.
AgentActivity _step(
  String id,
  String label, {
  AgentActivityStatus status = AgentActivityStatus.running,
}) => AgentActivity(
  id: id,
  kind: AgentActivityKind.command,
  label: label,
  status: status,
);

/// Chat state with one conversation in [_project], optionally mid-turn.
ChatSessionsState _chatsWith({
  required String chatId,
  bool running = false,
  bool sending = false,
  String? error,
  List<ChatMessage> messages = const [],
}) {
  var state = ChatSessionsState(
    conversations: [
      _chat(
        id: chatId,
        projectId: 'p-1',
        at: DateTime(2026, 8, 14),
        messages: messages,
      ),
    ],
    runningAgentIds: running ? {chatId} : const {},
  );
  if (sending) state = state.withPhase(chatId, const SendBusy());
  if (error != null) state = state.withError(chatId, error);
  return state;
}

void main() {
  group('the tile a project becomes', () {
    test('carries the assistant it uses, so the panel can show it', () {
      final tile = panelProjectFor(
        const Project(
          id: 'p-1',
          name: 'grid-app',
          path: '/tmp/grid-app',
          agent: 'claude',
          model: 'auto',
        ),
        const ChatSessionsState(),
      );
      expect(tile.agent, 'claude');
      expect(tile.model, 'auto');
      expect(tile.busy, isFalse);
    });

    test('recaps the last thing the assistant said, in one line', () {
      final tile = panelProjectFor(
        _project,
        ChatSessionsState(
          conversations: [
            _chat(
              id: 'c-1',
              projectId: 'p-1',
              at: DateTime(2026, 8, 13),
              messages: [
                _said('An earlier answer'),
                const ChatMessage(role: ChatRole.user, text: 'and now run it'),
                _said('## Ran the tests\nAll 1599 passed.'),
              ],
            ),
          ],
        ),
      );
      // The heading markup would arrive on a 480px tile as punctuation, and the
      // second line is not what the user last read.
      expect(tile.recap, 'Ran the tests');
    });

    test('a project nobody has talked in yet sends no recap at all', () {
      final tile = panelProjectFor(_project, const ChatSessionsState());
      expect(tile.recap, isEmpty);
      expect(tile.toJson().containsKey('recap'), isFalse);
    });

    test('the recap comes from the newest chat, not the pinned one', () {
      // The sidebar floats pinned chats to the top, which is right for
      // something the user clicks and wrong for "what happened here last".
      final tile = panelProjectFor(
        _project,
        ChatSessionsState(
          conversations: [
            _chat(
              id: 'pinned',
              projectId: 'p-1',
              at: DateTime(2026, 8, 1),
              messages: [_said('Old news')],
              pinned: true,
            ),
            _chat(
              id: 'newest',
              projectId: 'p-1',
              at: DateTime(2026, 8, 13),
              messages: [_said('Fresh news')],
            ),
          ],
        ),
      );
      expect(tile.recap, 'Fresh news');
    });

    test('an archived chat is not what the project last did', () {
      final tile = panelProjectFor(
        _project,
        ChatSessionsState(
          conversations: [
            _chat(
              id: 'filed',
              projectId: 'p-1',
              at: DateTime(2026, 8, 14),
              messages: [_said('Filed away')],
              archivedAt: DateTime(2026, 8, 14),
            ),
            _chat(
              id: 'live',
              projectId: 'p-1',
              at: DateTime(2026, 8, 13),
              messages: [_said('Still here')],
            ),
          ],
        ),
      );
      expect(tile.recap, 'Still here');
    });

    test('a turn running in any of its chats makes the tile busy', () {
      // Turns are serialized per project, so the chat holding the lane is what
      // makes the tile busy — and it need not be the one the recap came from.
      final chats = ChatSessionsState(
        conversations: [
          _chat(
            id: 'c-1',
            projectId: 'p-1',
            at: DateTime(2026, 8, 13),
            messages: [_said('Answered already')],
          ),
          _chat(id: 'c-2', projectId: 'p-1', at: DateTime(2026, 8, 12)),
        ],
        runningAgentIds: const {'c-2'},
      );
      expect(panelProjectFor(_project, chats).busy, isTrue);
    });

    test("another project's turn never lights up this tile", () {
      final chats = ChatSessionsState(
        conversations: [
          _chat(id: 'other', projectId: 'p-2', at: DateTime(2026, 8, 13)),
        ],
        runningAgentIds: const {'other'},
      );
      expect(panelProjectFor(_project, chats).busy, isFalse);
    });

    test('the tiles keep the order the app itself lists projects in', () {
      final tiles = panelProjectsFor(
        projects: const [
          Project(id: 'p-2', name: 'notes', path: '/tmp/notes'),
          _project,
        ],
        chats: const ChatSessionsState(),
      );
      expect(tiles.map((t) => t.name).toList(), ['notes', 'grid-app']);
    });
  });

  group('the turn a panel is shown', () {
    test('reads as one ordered timeline — a passage, then the step it ran, '
        'with where that step got to', () {
      final parts = panelTurnPartsFor([
        const TurnText('Reading the config'),
        TurnStep(_step('s1', 'grep -n foo lib/')),
      ]);
      expect(parts.map((p) => p.toJson()).toList(), [
        {'k': 't', 'text': 'Reading the config'},
        {'k': 's', 'label': 'grep -n foo lib/', 'status': 'running'},
      ]);
    });

    test('a long turn is cut to its most recent parts, because a frame that '
        'does not fit is dropped whole rather than shortened', () {
      final parts = panelTurnPartsFor([
        for (var i = 0; i < 40; i++) TurnStep(_step('s$i', 'step $i')),
      ]);
      expect(parts, hasLength(kPanelTurnPartLimit));
      // The newest end: what the agent is doing *now* is what a glance at the
      // tile is for.
      expect(parts.last.label, 'step 39');
      expect(parts.first.label, 'step ${40 - kPanelTurnPartLimit}');
    });

    test('a passage longer than the tile can draw is clipped, and says so', () {
      final parts = panelTurnPartsFor([TurnText('x' * 5000)]);
      expect(parts.single.label.length, kPanelPartTextLimit + 1);
      expect(parts.single.label.endsWith('…'), isTrue);
    });

    test('a timeline in a three-byte-a-character language still fits a frame, '
        'which the part count alone does not guarantee', () {
      // The frame *refuses* an over-long payload rather than truncating it, so
      // an arithmetic cap measured in characters is not a bound on bytes.
      final message = panelTurnPartsMessage(
        projectId: 'p-1',
        parts: panelTurnPartsFor([
          for (var i = 0; i < kPanelTurnPartLimit; i++)
            TurnText('${'漢' * kPanelPartTextLimit}$i'),
        ]),
      );
      expect(utf8.encode(message).length, lessThanOrEqualTo(kPanelMaxPayload));
      // And it still says something — trimmed, not emptied.
      expect((jsonDecode(message) as Map)['parts'], isNotEmpty);
    });

    test('a part with nothing to draw is dropped, not sent as a blank row', () {
      final parts = panelTurnPartsFor([
        const TurnText('   \n  '),
        TurnStep(_step('s1', '  ')),
        const TurnText('Real words'),
      ]);
      expect(parts.map((p) => p.label).toList(), ['Real words']);
    });
  });

  group('keeping a panel up to date with a turn', () {
    const projects = [_project];

    test('a project that starts working is announced once, and its timeline '
        'follows as the agent produces it', () {
      final mirror = PanelTurnMirror();
      final running = _chatsWith(chatId: 'c-1', running: true, sending: true);

      final first = mirror.onChange(
        projects: projects,
        chats: running,
        runs: const {},
      );
      expect(first, hasLength(1));
      expect(jsonDecode(first.single), {
        't': 'turn.started',
        'projectId': 'p-1',
      });

      final next = mirror.onChange(
        projects: projects,
        chats: running,
        runs: {
          'c-1': AgentRun(parts: [TurnStep(_step('s1', 'flutter test'))]),
        },
      );
      expect(jsonDecode(next.single), {
        't': 'turn.parts',
        'projectId': 'p-1',
        'parts': [
          {'k': 's', 'label': 'flutter test', 'status': 'running'},
        ],
      });
    });

    test('a timeline that has not moved is not sent again — the link carries '
        'the whole turn on every change, and a turn streams', () {
      final mirror = PanelTurnMirror();
      final chats = _chatsWith(chatId: 'c-1', running: true, sending: true);
      final runs = {
        'c-1': AgentRun(parts: [TurnStep(_step('s1', 'flutter test'))]),
      };
      mirror.onChange(projects: projects, chats: chats, runs: runs);
      mirror.onChange(projects: projects, chats: chats, runs: runs);

      expect(
        mirror.onChange(projects: projects, chats: chats, runs: runs),
        isEmpty,
      );
    });

    test('a turn that lands is reported done, with the last line said in it '
        'so the tile has something to show afterwards', () {
      final mirror = PanelTurnMirror();
      mirror.onChange(
        projects: projects,
        chats: _chatsWith(chatId: 'c-1', running: true, sending: true),
        runs: const {},
      );

      final done = mirror.onChange(
        projects: projects,
        chats: _chatsWith(
          chatId: 'c-1',
          messages: [_said('## Ran the tests\nAll 1599 passed.')],
        ),
        runs: const {},
      );
      expect(jsonDecode(done.single), {
        't': 'turn.done',
        'projectId': 'p-1',
        'recap': 'Ran the tests',
      });
    });

    test('a turn that failed reports the failure, not a done it never was', () {
      final mirror = PanelTurnMirror();
      mirror.onChange(
        projects: projects,
        chats: _chatsWith(chatId: 'c-1', running: true, sending: true),
        runs: const {},
      );

      final failed = mirror.onChange(
        projects: projects,
        chats: _chatsWith(chatId: 'c-1', error: 'Hermes stopped answering'),
        runs: const {},
      );
      expect(jsonDecode(failed.single), {
        't': 'turn.error',
        'projectId': 'p-1',
        'message': 'Hermes stopped answering',
      });
    });

    test('a project the app does not list is never mentioned — the panel was '
        'never sent a tile for it', () {
      final mirror = PanelTurnMirror();
      expect(
        mirror.onChange(
          projects: const [],
          chats: _chatsWith(chatId: 'c-1', running: true, sending: true),
          runs: const {},
        ),
        isEmpty,
      );
    });

    test('a panel that plugs in mid-turn is given the turn it walked in on, '
        'timeline and all', () {
      final mirror = PanelTurnMirror();
      final messages = mirror.onAttach(
        projects: projects,
        chats: _chatsWith(chatId: 'c-1', running: true, sending: true),
        runs: {
          'c-1': AgentRun(parts: [TurnStep(_step('s1', 'flutter test'))]),
        },
      );
      expect(
        [for (final m in messages) (jsonDecode(m) as Map)['t']],
        ['turn.started', 'turn.parts'],
      );
    });
  });

  group('answering a panel over the link', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_panel_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    /// A container with the link pointed at [transport] and every store in a
    /// temp dir — never the real `~/.grid`, and never a real cable.
    ///
    /// [grid] is the selected grid (null = a computer with none set up),
    /// [agent] the assistant that answers, and [models] what the grid serves.
    /// All three are pinned rather than read from the machine running the test:
    /// a turn started from the panel reaches for every one of them, and a real
    /// `hermes` on the tester's PATH would answer for real.
    ProviderContainer harness(
      _FakeTransport transport, {
      NetworkCredential? grid,
      ChatSender? agent,
      List<String> models = const [],
      SttClient? stt,
      PanelFirmwareImage? firmware,
    }) {
      final container = ProviderContainer(
        overrides: [
          panelLinkProvider.overrideWithValue(PanelLink(transport)),
          chatStoreProvider.overrideWithValue(ChatStore(directory: tmp)),
          projectsStoreProvider.overrideWithValue(
            ProjectsStore(file: File('${tmp.path}/projects.json')),
          ),
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
          ),
          mediaOutputsDirProvider.overrideWithValue(
            Directory('${tmp.path}/outputs'),
          ),
          selectedNetworkProvider.overrideWith(() => _PickedNetwork(grid)),
          // Hermes answers when a fake is handed in, and nobody does otherwise
          // — every other agent is pinned absent so a real one installed on this
          // machine can never take the turn and spawn a process mid-test.
          hermesPathProvider.overrideWithValue(
            agent == null ? null : '/bin/hs',
          ),
          codexPathProvider.overrideWithValue(null),
          claudePathProvider.overrideWithValue(null),
          piPathProvider.overrideWithValue(null),
          hermesChatSenderProvider.overrideWithValue(agent ?? _HeldTurn()),
          chatSenderProvider.overrideWithValue(agent ?? _HeldTurn()),
          // A turn stamps its reply with the machine behind the model; without
          // this it would reach for the live overview.
          gridOverviewProvider.overrideWith(
            (ref) => const GridOverview(
              stats: GridStats(models: 0, nodes: 0),
              models: [],
              nodes: [],
            ),
          ),
          playgroundModelsProvider.overrideWith(
            (ref) => [
              for (final id in models)
                PlaygroundModelOption(
                  id: id,
                  label: id,
                  modality: PlaygroundModality.text,
                ),
            ],
          ),
          nodeNameProvider.overrideWithValue('this-mac'),
          appVersionProvider.overrideWith((ref) async => '0.9.1'),
          // Both pinned absent by default: a test that says nothing about
          // voice must not reach the tester's `grid` binary, and one that says
          // nothing about firmware must not offer an update built from
          // whatever image happens to be in this checkout.
          sttClientProvider.overrideWithValue(stt),
          panelFirmwareProvider.overrideWith((ref) async => firmware),
        ],
      );
      addTearDown(container.dispose);
      container.read(panelControllerProvider).listen();
      return container;
    }

    test('a panel that says hello is answered, and told which machine '
        'it is looking at', () async {
      final transport = _FakeTransport();
      harness(transport);

      transport.deliver(
        '{"t":"hello","fw":"0.1.0","proto":1,"mac":"A4:CB:8F:CF:D0:78"}',
      );
      await pumpEventQueue();

      final welcome = transport.replies.single;
      expect(welcome['t'], 'welcome');
      expect(welcome['proto'], 1);
      expect(welcome['app'], '0.9.1');
      expect((welcome['machine']! as Map<String, Object?>)['id'], 'this-mac');
    });

    test('a panel on another protocol is still answered — the reply is how '
        'it learns which version to reflash to', () async {
      final transport = _FakeTransport();
      harness(transport);

      transport.deliver('{"t":"hello","fw":"9.0.0","proto":99,"mac":""}');
      await pumpEventQueue();

      expect(transport.replies.single['t'], 'welcome');
    });

    test('asking for the projects gets the real ones', () async {
      final transport = _FakeTransport();
      final container = harness(transport);
      await container.read(chatSessionsProvider.notifier).restored;
      final projects = container.read(projectsProvider.notifier);
      projects.create(path: '${tmp.path}/api', name: 'api');
      final notes = projects.create(path: '${tmp.path}/notes', name: 'notes');
      projects.setPinned(notes.id, true);

      transport.deliver('{"t":"projects.list"}');
      await pumpEventQueue();

      final reply = transport.replies.single;
      expect(reply['t'], 'projects');
      final items = (reply['items']! as List).cast<Map<String, Object?>>();
      // Pinned first, exactly as the rail shows them.
      expect(items.map((i) => i['name']).toList(), ['notes', 'api']);
      expect(items.first['busy'], false);
    });

    test(
      'a turn for a project this computer no longer has is refused in words, '
      'not by silence',
      () async {
        // Silence would leave the tile spinning on work that is never coming,
        // and the panel has no other way to find out — it reads no disk and
        // cannot see the window.
        final transport = _FakeTransport();
        final container = harness(transport, grid: _credential());
        await container.read(chatSessionsProvider.notifier).restored;

        transport.deliver('{"t":"turn.send","projectId":"p-1","text":"hi"}');
        await pumpEventQueue();

        final reply = transport.replies.single;
        expect(reply['t'], 'turn.error');
        expect(reply['projectId'], 'p-1');
        expect(reply['message'], contains('project'));
      },
    );

    test('a turn asked for with no grid set up says which step is missing, so '
        'the answer is something the user can go and do', () async {
      final transport = _FakeTransport();
      final container = harness(transport, agent: _HeldTurn());
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}","text":"hi"}',
      );
      await pumpEventQueue();

      final reply = transport.replies.single;
      expect(reply['t'], 'turn.error');
      expect(reply['message'], contains('Open Grid'));
    });

    test('a turn asked for on a grid serving no models says so rather than '
        'sending a turn nothing can answer', () async {
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: _HeldTurn(),
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}","text":"hi"}',
      );
      await pumpEventQueue();

      final reply = transport.replies.single;
      expect(reply['t'], 'turn.error');
      expect(reply['message'], contains('model'));
    });

    test('a turn typed on the panel really goes to the assistant, and the '
        'panel is told the turn has started', () async {
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}",'
        '"text":"run the tests"}',
      );
      await pumpEventQueue();

      // A project nobody has talked in yet gets a chat of its own, opened in
      // the folder the agent then works in.
      expect(agent.history!.last.text, 'run the tests');
      expect(agent.workdir, project.path);
      expect(agent.model, 'qwen');
      final started = transport.replies.single;
      expect(started['t'], 'turn.started');
      expect(started['projectId'], project.id);
    });

    test('a turn already running in the project is said out loud rather than '
        'quietly starting a second one', () async {
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      const ask = '{"t":"turn.send","projectId":"PID","text":"go"}';
      transport.deliver(ask.replaceAll('PID', project.id));
      await pumpEventQueue();
      transport.deliver(ask.replaceAll('PID', project.id));
      await pumpEventQueue();

      final replies = transport.replies;
      expect(replies.first['t'], 'turn.started');
      expect(replies.last['t'], 'turn.error');
      expect(replies.last['message'], contains('already working'));
      // And the second ask never reached the assistant.
      expect(agent.history, hasLength(1));
    });

    test('the panel watches a turn happen — it starts, the steps arrive as '
        'they are run, and it lands with a recap', () async {
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}","text":"run them"}',
      );
      await pumpEventQueue();

      final chatId = container
          .read(chatSessionsProvider)
          .conversations
          .single
          .id;
      final runs = container.read(agentRunsProvider.notifier);
      runs.upsertStep(
        chatId,
        _step('s1', 'flutter test'),
        answer: 'Running it',
      );
      runs.upsertStep(
        chatId,
        _step('s1', 'flutter test', status: AgentActivityStatus.done),
      );
      await pumpEventQueue();

      await agent.answer('All 1599 passed.');
      await pumpEventQueue();

      final kinds = [for (final r in transport.replies) r['t']];
      expect(kinds.first, 'turn.started');
      expect(kinds, contains('turn.parts'));
      expect(kinds.last, 'turn.done');

      // The timeline reads in the order it happened: what it said, then what
      // it ran with the status that step got to, then the closing words the
      // landing folds in.
      final parts = transport.replies.lastWhere(
        (r) => r['t'] == 'turn.parts',
      )['parts']!;
      expect((parts as List).cast<Map<String, Object?>>(), [
        {'k': 't', 'text': 'Running it'},
        {'k': 's', 'label': 'flutter test', 'status': 'done'},
        {'k': 't', 'text': 'All 1599 passed.'},
      ]);
      expect(transport.replies.last['recap'], 'All 1599 passed.');
    });

    test('a turn that fails reaches the panel as the failure, in the same '
        'words the window shows', () async {
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}","text":"run them"}',
      );
      await pumpEventQueue();
      await agent.fail('Hermes stopped answering');
      await pumpEventQueue();

      final last = transport.replies.last;
      expect(last['t'], 'turn.error');
      expect(last['message'], 'Hermes stopped answering');
    });

    test(
      'a message this build has never heard of leaves the link up',
      () async {
        // Newer firmware must read as a version mismatch, never as a link that
        // connects and then dies on the first unknown word.
        final transport = _FakeTransport();
        harness(transport);

        transport.deliver('{"t":"screen.brightness","level":40}');
        transport.deliver('{"t":"hello","fw":"0.1.0","proto":1,"mac":"AA"}');
        await pumpEventQueue();

        expect(transport.replies.single['t'], 'welcome');
      },
    );

    test(
      'stopping a project the desktop never opened is a no-op, not a crash',
      () async {
        final transport = _FakeTransport();
        final container = harness(transport);
        await container.read(chatSessionsProvider.notifier).restored;

        transport.deliver('{"t":"turn.stop","projectId":"p-nowhere"}');
        await pumpEventQueue();

        expect(transport.replies, isEmpty);
      },
    );

    /// 100 ms of the sort of thing a microphone produces.
    final pcm = [for (var i = 0; i < 3200; i++) i % 256];

    test(
      'a sentence spoken at a project tile is transcribed and dispatched '
      'there — no confirmation, because the panel named the project',
      () async {
        final agent = _HeldTurn();
        final stt = _FakeStt(const SttSuccess('run the tests'));
        final transport = _FakeTransport();
        final container = harness(
          transport,
          grid: _credential(),
          agent: agent,
          models: const ['qwen'],
          stt: stt,
        );
        await container.read(chatSessionsProvider.notifier).restored;
        final project = container
            .read(projectsProvider.notifier)
            .create(path: '${tmp.path}/api', name: 'api');

        transport.deliver('{"t":"voice.begin","projectId":"${project.id}"}');
        transport.deliverAudio(pcm);
        transport.deliver('{"t":"voice.end"}');
        await pumpEventQueue();

        final transcript = transport.replies.firstWhere(
          (r) => r['t'] == 'voice.transcript',
        );
        expect(transcript['text'], 'run the tests');
        expect(transcript['projectId'], project.id);
        expect(transcript['needsConfirm'], false);
        // The turn goes through the same path `turn.send` uses, so the panel
        // watches it exactly as it watches a typed one.
        expect(agent.history!.last.text, 'run the tests');
        expect(transport.replies.last['t'], 'turn.started');
        // And what was transcribed is the audio the panel actually sent, in a
        // container the CLI can read.
        expect(String.fromCharCodes(stt.clip!.sublist(0, 4)), 'RIFF');
        expect(stt.clip!.sublist(kWavHeaderBytes), pcm);
        expect(stt.lang, anyOf('en', 'vi'));
      },
    );

    test(
      'the Goal pill puts /goal in front of what was heard, so the panel\'s '
      'modifier reaches the agent as part of the sentence',
      () async {
        final agent = _HeldTurn();
        final transport = _FakeTransport();
        final container = harness(
          transport,
          grid: _credential(),
          agent: agent,
          models: const ['qwen'],
          stt: _FakeStt(const SttSuccess('ship the release')),
        );
        await container.read(chatSessionsProvider.notifier).restored;
        final project = container
            .read(projectsProvider.notifier)
            .create(path: '${tmp.path}/api', name: 'api');

        transport.deliver(
          '{"t":"voice.begin","projectId":"${project.id}","cmd":"goal"}',
        );
        transport.deliverAudio(pcm);
        transport.deliver('{"t":"voice.end"}');
        await pumpEventQueue();

        // Prefixed once, in one place: the transcript the panel is shown and
        // the message the agent receives are the same string.
        final transcript = transport.replies.firstWhere(
          (r) => r['t'] == 'voice.transcript',
        );
        expect(transcript['text'], '/goal ship the release');
        expect(agent.history!.last.text, '/goal ship the release');
      },
    );

    test(
      'a modifier this build has never heard of is dropped rather than pasted '
      'in front of the words',
      () async {
        // A newer panel offering a pill this app does not know must still get
        // its sentence through — mangled words are worse than a lost modifier.
        final agent = _HeldTurn();
        final transport = _FakeTransport();
        final container = harness(
          transport,
          grid: _credential(),
          agent: agent,
          models: const ['qwen'],
          stt: _FakeStt(const SttSuccess('ship it')),
        );
        await container.read(chatSessionsProvider.notifier).restored;
        final project = container
            .read(projectsProvider.notifier)
            .create(path: '${tmp.path}/api', name: 'api');

        transport.deliver(
          '{"t":"voice.begin","projectId":"${project.id}","cmd":"lasso"}',
        );
        transport.deliverAudio(pcm);
        transport.deliver('{"t":"voice.end"}');
        await pumpEventQueue();

        expect(agent.history!.last.text, 'ship it');
      },
    );

    test('a sentence spoken from a screen that names no project is guessed at '
        'and asked about, never dispatched on the guess', () async {
      // A guess that dispatches itself into a real repository is worse than
      // one extra tap.
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
        stt: _FakeStt(const SttSuccess('deploy it')),
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver('{"t":"voice.begin"}');
      transport.deliverAudio(pcm);
      transport.deliver('{"t":"voice.end"}');
      await pumpEventQueue();

      final transcript = transport.replies.single;
      expect(transcript['t'], 'voice.transcript');
      expect(transcript['needsConfirm'], true);
      expect(transcript['projectId'], project.id);
      expect(agent.history, isNull);

      // Confirming is what dispatches it, and the project the user picked wins
      // over the one the app guessed.
      final other = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/notes', name: 'notes');
      transport.deliver(
        '{"t":"voice.confirm","routeId":"${transcript['routeId']}",'
        '"projectId":"${other.id}"}',
      );
      await pumpEventQueue();

      expect(agent.history!.last.text, 'deploy it');
      expect(agent.workdir, other.path);
    });

    test('a confirmation for a transcript nobody is holding is answered, not '
        'ignored — the panel is waiting on something', () async {
      final transport = _FakeTransport();
      final container = harness(transport, grid: _credential());
      await container.read(chatSessionsProvider.notifier).restored;

      transport.deliver(
        '{"t":"voice.confirm","routeId":"r-9","projectId":"p"}',
      );
      await pumpEventQueue();

      expect(transport.replies.single['t'], 'voice.error');
    });

    test('a transcription that fails reaches the panel in the words the CLI '
        'used, which name what to do about it', () async {
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        stt: _FakeStt(
          const SttFailure(
            'Your Grid session has expired. Run `grid login` to sign in again.',
          ),
        ),
      );
      await container.read(chatSessionsProvider.notifier).restored;
      container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver('{"t":"voice.begin"}');
      transport.deliverAudio(pcm);
      transport.deliver('{"t":"voice.end"}');
      await pumpEventQueue();

      final reply = transport.replies.single;
      expect(reply['t'], 'voice.error');
      expect(reply['message'], contains('grid login'));
    });

    test('a capture with no audio in it says so rather than sending a clip '
        'there is nothing in to transcribe', () async {
      final stt = _FakeStt(const SttSuccess('never asked'));
      final transport = _FakeTransport();
      final container = harness(transport, grid: _credential(), stt: stt);
      await container.read(chatSessionsProvider.notifier).restored;

      transport.deliver('{"t":"voice.begin"}');
      transport.deliver('{"t":"voice.end"}');
      await pumpEventQueue();

      expect(transport.replies.single['t'], 'voice.error');
      expect(transport.replies.single['message'], contains('microphone'));
      expect(stt.clip, isNull);
    });

    test('voice with no grid tool on this computer says which tool is missing '
        'instead of leaving the panel listening', () async {
      final transport = _FakeTransport();
      final container = harness(transport, grid: _credential());
      await container.read(chatSessionsProvider.notifier).restored;

      transport.deliver('{"t":"voice.begin"}');
      transport.deliverAudio(pcm);
      transport.deliver('{"t":"voice.end"}');
      await pumpEventQueue();

      expect(transport.replies.single['message'], contains('grid tool'));
    });

    test('a panel running another firmware is offered the one this build '
        'carries, with the hash the device verifies against', () async {
      final image = PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!;
      final transport = _FakeTransport();
      harness(transport, firmware: image);

      transport.deliver('{"t":"hello","fw":"v0.4.0","proto":1,"mac":"AA"}');
      await pumpEventQueue();

      final offer = transport.replies.firstWhere((r) => r['t'] == 'fw.offer');
      expect(offer['version'], 'v0.4.1');
      expect(offer['size'], image.size);
      expect(offer['sha256'], image.sha256);
      // Nothing until the panel accepts: it decides when it is willing.
      expect(transport.imageFrames, isEmpty);
    });

    test(
      'a panel already running this build\'s firmware is left alone',
      () async {
        final transport = _FakeTransport();
        harness(
          transport,
          firmware: PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!,
        );

        transport.deliver('{"t":"hello","fw":"v0.4.1","proto":1,"mac":"AA"}');
        await pumpEventQueue();

        expect(transport.replies.single['t'], 'welcome');
      },
    );

    test('no update is offered while a turn is running, because accepting one '
        'reboots the panel out of work someone is watching', () async {
      final agent = _HeldTurn();
      final transport = _FakeTransport();
      final container = harness(
        transport,
        grid: _credential(),
        agent: agent,
        models: const ['qwen'],
        firmware: PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!,
      );
      await container.read(chatSessionsProvider.notifier).restored;
      final project = container
          .read(projectsProvider.notifier)
          .create(path: '${tmp.path}/api', name: 'api');

      transport.deliver(
        '{"t":"turn.send","projectId":"${project.id}","text":"run them"}',
      );
      await pumpEventQueue();
      transport.deliver('{"t":"hello","fw":"v0.4.0","proto":1,"mac":"AA"}');
      await pumpEventQueue();

      expect(transport.replies.any((r) => r['t'] == 'fw.offer'), isFalse);

      // It is offered when the machine goes idle — the panel will not say
      // hello again until it is unplugged.
      await agent.answer('All 1599 passed.');
      await pumpEventQueue();
      expect(transport.replies.any((r) => r['t'] == 'fw.offer'), isTrue);
    });

    test('a panel that accepts is sent the image, in order, on its own frame '
        'type, as it acknowledges each slice', () async {
      final image = PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!;
      final transport = _FakeTransport();
      harness(transport, firmware: image);

      transport.deliver('{"t":"hello","fw":"v0.4.0","proto":1,"mac":"AA"}');
      await pumpEventQueue();
      transport.deliver('{"t":"fw.accept"}');
      await pumpEventQueue();

      // Play the panel: acknowledge everything received so far, which is what
      // opens the window for the next slice. Bounded so a transfer that stops
      // moving fails the test instead of hanging it.
      var sent = 0;
      for (var turn = 0; turn < 100; turn++) {
        final now = transport.imageFrames.fold<int>(0, (n, f) => n + f.length);
        if (now == image.bytes.length) break;
        expect(now, greaterThan(sent), reason: 'the transfer stopped moving');
        sent = now;
        transport.deliver('{"t":"fw.progress","written":$now}');
        await pumpEventQueue();
      }

      expect([
        for (final frame in transport.imageFrames) ...frame,
      ], image.bytes);
    });

    test('never has more than the credit window unacknowledged, because the '
        'panel drops what it cannot buffer without telling anyone', () async {
      final image = PanelFirmwareImage.read(espAppImage(version: 'v0.4.1'))!;
      final transport = _FakeTransport();
      harness(transport, firmware: image);

      transport.deliver('{"t":"hello","fw":"v0.4.0","proto":1,"mac":"AA"}');
      await pumpEventQueue();
      transport.deliver('{"t":"fw.accept"}');
      await pumpEventQueue();

      // Not one byte more than the window before the first acknowledgement.
      // This is the assertion that would have caught the first real transfer:
      // it pushed 128 KB into a device whose receive ring held 1 KB, and the
      // ~16 ms each slice spends in flash meant almost none of it survived.
      // There is no NAK on that peripheral, so nothing else can catch it.
      final unacked = transport.imageFrames.fold<int>(
        0,
        (n, f) => n + f.length,
      );
      expect(unacked, lessThanOrEqualTo(kPanelFirmwareWindowBytes));
      expect(unacked, greaterThan(0));
    });
  });
}
