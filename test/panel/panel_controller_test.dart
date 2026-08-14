import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/panel/logic/panel_controller.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/panel/panel_frame.dart';
import 'package:grid_app/infrastructure/panel/panel_link.dart';
import 'package:grid_app/infrastructure/panel/panel_link_provider.dart';
import 'package:grid_app/shared/app_info.dart';

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

  /// Everything the app has said, decoded back through the real framing.
  List<Map<String, Object?>> get replies {
    final decoder = PanelFrameDecoder();
    return [
      for (final chunk in sent)
        for (final frame in decoder.feed(chunk))
          jsonDecode(frame.text) as Map<String, Object?>,
    ];
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

  group('answering a panel over the link', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_panel_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    /// A container with the link pointed at [transport] and every store in a
    /// temp dir — never the real `~/.grid`, and never a real cable.
    ProviderContainer harness(_FakeTransport transport) {
      final container = ProviderContainer(
        overrides: [
          panelLinkProvider.overrideWithValue(PanelLink(transport)),
          chatStoreProvider.overrideWithValue(ChatStore(directory: tmp)),
          projectsStoreProvider.overrideWithValue(
            ProjectsStore(file: File('${tmp.path}/projects.json')),
          ),
          nodeNameProvider.overrideWithValue('this-mac'),
          appVersionProvider.overrideWith((ref) async => '0.9.1'),
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
      'a turn typed on the panel is refused in words, not by silence',
      () async {
        // Sending turns is a later milestone. Saying nothing would leave the tile
        // spinning on work that is never coming.
        final transport = _FakeTransport();
        harness(transport);

        transport.deliver('{"t":"turn.send","projectId":"p-1","text":"hi"}');
        await pumpEventQueue();

        final reply = transport.replies.single;
        expect(reply['t'], 'turn.error');
        expect(reply['projectId'], 'p-1');
        expect(reply['message'], isNotEmpty);
      },
    );

    test(
      'a message this build has never heard of leaves the link up',
      () async {
        // Newer firmware must read as a version mismatch, never as a link that
        // connects and then dies on the first unknown word.
        final transport = _FakeTransport();
        harness(transport);

        transport.deliver('{"t":"voice.begin","projectId":"p-1"}');
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
  });
}
