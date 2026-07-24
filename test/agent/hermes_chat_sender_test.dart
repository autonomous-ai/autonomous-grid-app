import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_permissions.dart';
import 'package:grid_app/features/agent/logic/agent_providers.dart';
import 'package:grid_app/features/agent/logic/hermes_chat_sender.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_service.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'grid-1',
  name: 'Test grid',
  networkType: 'permissioned-providers',
  lanSignalingUrl: 'https://grid.example/grid-1',
  accessToken: 'secret-token',
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

/// A [HermesAcpService] whose sessions replay a scripted turn's events and
/// record every prompt, so a test can assert on session reuse and on the exact
/// text each turn sent. [_turns] is a list of turns; each turn is the events to
/// replay for that `prompt` call.
class _FakeAcp implements HermesAcpService {
  _FakeAcp(this._turns);

  /// One-turn convenience matching the common case.
  _FakeAcp.single(List<HermesAcpEvent> events) : _turns = [events];

  final List<List<HermesAcpEvent>> _turns;
  final sessions = <_FakeAcpSession>[];

  int get startCount => sessions.length;

  /// Every prompt across every session, in order — the text each turn sent.
  List<String> get prompts => [for (final s in sessions) ...s.prompts];

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    final session = _FakeAcpSession(_turns, 'sess-${sessions.length + 1}');
    sessions.add(session);
    return session;
  }
}

/// A [HermesAcpService] whose every start fails, standing in for a machine where
/// `hermes acp` won't come up (a missing dependency, a broken install).
class _FailingAcp implements HermesAcpService {
  _FailingAcp(this._error);

  final HermesAcpException _error;

  @override
  Future<HermesAcpSession> start({required String workdir}) async =>
      throw _error;
}

class _FakeAcpSession implements HermesAcpSession {
  _FakeAcpSession(this._turns, this.sessionId);

  final List<List<HermesAcpEvent>> _turns;
  final prompts = <String>[];
  int _turn = 0;
  bool _closed = false;

  /// The mode each turn was sent under.
  final modes = <AgentApprovalMode>[];

  @override
  final String sessionId;

  @override
  set approvalMode(AgentApprovalMode mode) => modes.add(mode);

  @override
  bool get isClosed => _closed;

  @override
  HermesAcpRun prompt(String text) {
    prompts.add(text);
    final events = _turn < _turns.length
        ? _turns[_turn]
        : const <HermesAcpEvent>[];
    _turn++;
    return HermesAcpRun(
      events: Stream.fromIterable(events),
      done: Future.value(),
      kill: () {},
    );
  }

  @override
  void answerPermission(Object requestId, String? optionId) {}

  @override
  Future<void> close() async => _closed = true;
}

/// A session whose turn stays open, so a test can drive events into a live turn
/// — a permission request stalls the agent until it's answered, which a canned
/// list of events can't express.
class _LiveAcp implements HermesAcpService {
  final session = _LiveAcpSession();

  @override
  Future<HermesAcpSession> start({required String workdir}) async => session;
}

class _LiveAcpSession implements HermesAcpSession {
  final events = StreamController<HermesAcpEvent>();
  final _done = Completer<void>();

  /// Every permission answered, as (request id, chosen option).
  final answers = <(Object, String?)>[];

  @override
  final String sessionId = 'sess-live';

  @override
  set approvalMode(AgentApprovalMode mode) {}

  @override
  bool get isClosed => false;

  @override
  HermesAcpRun prompt(String text) =>
      HermesAcpRun(events: events.stream, done: _done.future, kill: _end);

  @override
  void answerPermission(Object requestId, String? optionId) =>
      answers.add((requestId, optionId));

  /// The turn ends: what the agent was going to say, then done.
  void finish(String reply) {
    events.add(HermesAcpMessage(reply));
    _end();
  }

  /// Killing the turn settles it, as closing the real process does.
  void _end() {
    if (_done.isCompleted) return;
    events.close();
    _done.complete();
  }

  @override
  Future<void> close() async => _end();
}

/// Wait until the turn is actually live — the sender writes Hermes's config and
/// starts the session first, and that's file I/O, which a drained microtask
/// queue says nothing about.
Future<void> _untilListening(_LiveAcp service) async {
  for (var i = 0; i < 500 && !service.session.events.hasListener; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    service.session.events.hasListener,
    isTrue,
    reason: 'turn never began',
  );
}

const _permission = AgentPermission(
  id: 7,
  kind: AgentPermissionKind.command,
  summary: 'Delete the build folder',
  command: 'rm -rf build',
  options: [
    (optionId: 'allow_once', kind: 'allow_once'),
    (optionId: 'deny', kind: 'reject_once'),
  ],
);

ProviderContainer _container(HermesAcpService? service, Directory tmp) {
  final container = ProviderContainer(
    overrides: [
      hermesAcpServiceProvider.overrideWithValue(service),
      agentWorkspaceDirProvider.overrideWithValue(Directory('${tmp.path}/ws')),
      clientAppConfiguratorProvider.overrideWithValue(
        ClientAppConfigurator(home: tmp.path),
      ),
      // The approval mode is read from here — never from the real `~/.grid`.
      chatPrefsStoreProvider.overrideWithValue(
        ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<ChatMessage> _history(String text) => [
  ChatMessage(role: ChatRole.user, text: text),
];

AgentActivity _step(String id, AgentActivityStatus status) => AgentActivity(
  id: id,
  kind: AgentActivityKind.command,
  label: 'terminal: ls',
  status: status,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_hermes_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('streams the answer as it arrives, then joins the chunks', () async {
    final service = _FakeAcp.single([
      HermesAcpActivity(_step('tc1', AgentActivityStatus.running)),
      HermesAcpActivity(_step('tc1', AgentActivityStatus.done)),
      const HermesAcpMessage('PANGO'),
      const HermesAcpMessage('LIN'),
    ]);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('read notes'),
        )
        .toList();

    // The answer streams in cumulatively before the terminal success.
    final streamed = updates.whereType<ChatSendStreaming>().toList();
    expect(streamed.map((u) => u.text), ['PANGO', 'PANGOLIN']);
    expect(updates.last, isA<ChatSendSuccess>());
    expect((updates.last as ChatSendSuccess).reply.text, 'PANGOLIN');
    // The activity feed collapsed the started→done tool into one done step.
    final steps = container.read(agentActivityProvider);
    expect(steps, hasLength(1));
    expect(steps.single.status, AgentActivityStatus.done);
    // Pointed Hermes at the grid.
    expect(File('${tmp.path}/.hermes/config.yaml').existsSync(), isTrue);
  });

  test(
    'web sources found mid-turn are pinned onto the answer and shown live',
    () async {
      const sources = [
        WebSource(title: 'Flutter', url: 'https://flutter.dev'),
        WebSource(title: 'Dart', url: 'https://dart.dev'),
      ];
      final service = _FakeAcp.single([
        HermesAcpActivity(
          AgentActivity(
            id: 'w1',
            kind: AgentActivityKind.web,
            label: 'web search: flutter',
            status: AgentActivityStatus.done,
          ),
        ),
        const HermesAcpSources(sources),
        const HermesAcpMessage('Here you go.'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'm',
            history: _history('flutter news'),
          )
          .toList();

      // The citations ride on the persisted answer…
      final reply = (updates.last as ChatSendSuccess).reply;
      expect(reply.sources.map((s) => s.url), [
        'https://flutter.dev',
        'https://dart.dev',
      ]);
      // …and were exposed live for the working bubble.
      expect(container.read(agentSourcesProvider).map((s) => s.url), [
        'https://flutter.dev',
        'https://dart.dev',
      ]);
    },
  );

  test(
    'the agent’s to-do plan is pinned onto the answer and shown live, replaced '
    'wholesale as it revises it',
    () async {
      final service = _FakeAcp.single([
        const HermesAcpPlan([
          AgentPlanEntry(content: 'Read', status: AgentPlanStatus.active),
          AgentPlanEntry(content: 'Write', status: AgentPlanStatus.pending),
        ]),
        // The agent revised the list — a full replacement, not a delta.
        const HermesAcpPlan([
          AgentPlanEntry(content: 'Read', status: AgentPlanStatus.done),
          AgentPlanEntry(content: 'Write', status: AgentPlanStatus.done),
        ]),
        const HermesAcpMessage('All done.'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('go'))
          .toList();

      // The final plan (both steps done) rides on the persisted answer…
      final reply = (updates.last as ChatSendSuccess).reply;
      expect(reply.plan.map((e) => e.content), ['Read', 'Write']);
      expect(reply.plan.map((e) => e.status), [
        AgentPlanStatus.done,
        AgentPlanStatus.done,
      ]);
      // …and the live provider holds that latest full list, not the union.
      expect(container.read(agentPlanProvider), hasLength(2));
    },
  );

  test('Plan mode planning turn runs read-only and asks the agent to plan, not '
      'act', () async {
    final service = _FakeAcp.single([
      const HermesAcpMessage('Here is my plan…'),
    ]);
    final container = _container(service, tmp);

    await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'm',
          history: _history('refactor the parser'),
          planFirst: true,
        )
        .toList();

    final session = service.sessions.single;
    // Forced read-only so the plan turn can touch nothing, whatever the composer
    // was set to…
    expect(session.modes.last, AgentApprovalMode.readOnly);
    // …and the request went out wrapped in the plan preamble.
    expect(session.prompts.single, contains('Planning mode'));
    expect(session.prompts.single, contains('refactor the parser'));
  });

  test(
    'the execute turn after an approved plan runs under Ask, not Plan',
    () async {
      final service = _FakeAcp.single([const HermesAcpMessage('Done.')]);
      final container = _container(service, tmp);
      // The composer is still on Plan, but this is the carry-it-out turn.
      container
          .read(chatPrefsProvider.notifier)
          .setApproval(AgentApprovalMode.plan);

      await container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'm',
            history: _history('do it'),
            planFirst: false,
          )
          .toList();

      // Plan maps to Ask on the execute turn — it gates each action, no preamble.
      expect(service.sessions.single.modes.last, AgentApprovalMode.ask);
      expect(
        service.sessions.single.prompts.single,
        isNot(contains('Planning mode')),
      );
    },
  );

  test('one live session per conversation — later turns send only the new '
      'message', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('hi there')],
      [const HermesAcpMessage('sure thing')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: const [ChatMessage(role: ChatRole.user, text: 'hello')],
        )
        .toList();

    // Second turn of the same conversation: history carries the whole thread.
    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: const [
            ChatMessage(role: ChatRole.user, text: 'hello'),
            ChatMessage(role: ChatRole.assistant, text: 'hi there'),
            ChatMessage(role: ChatRole.user, text: 'thanks'),
          ],
        )
        .toList();

    // The process was spawned once and reused.
    expect(service.startCount, 1);
    // First turn seeded context; the second sent only the new user turn, not
    // the whole history re-flattened.
    expect(service.prompts, ['hello', 'thanks']);
  });

  test('switching conversation starts a fresh session', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('a')],
      [const HermesAcpMessage('b')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: _history('one'),
        )
        .toList();
    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-2',
          history: _history('two'),
        )
        .toList();

    expect(service.startCount, 2);
    expect(service.sessions.first.isClosed, isTrue, reason: 'old one closed');
  });

  test('no agent installed says so in plain language', () async {
    final container = _container(null, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(updates.single, isA<ChatSendFailure>());
    // Plain language, with the screen that fixes it — no binary names.
    expect(
      (updates.single as ChatSendFailure).error,
      contains("isn't set up to answer chats yet"),
    );
  });

  test(
    'a startup that retrying cannot fix reports why, and does not say to retry',
    () async {
      // The real shape of this: hermes-agent installed without its `[acp]` extra,
      // so `hermes acp` dies on startup saying exactly this. Retrying is futile —
      // the message has to name the fault instead.
      final container = _container(
        _FailingAcp(
          const HermesAcpException(
            'Hermes exited during startup: ACP dependencies not installed.',
            retryable: false,
          ),
        ),
        tmp,
      );

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'qwen/qwen3.6-27b',
            history: _history('hi'),
          )
          .toList();

      final error = (updates.single as ChatSendFailure).error;
      expect(error, contains('ACP dependencies not installed'));
      expect(
        error,
        isNot(contains('Try sending again')),
        reason: 'retrying a missing dependency fails identically every time',
      );
    },
  );

  test('a startup that might succeed next time still says to retry', () async {
    final container = _container(
      _FailingAcp(
        const HermesAcpException('Hermes could not start: spawn failed'),
      ),
      tmp,
    );

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(
      (updates.single as ChatSendFailure).error,
      contains('Try sending again'),
    );
  });

  test('a turn with no answer text is a failure', () async {
    final service = _FakeAcp.single([
      HermesAcpActivity(_step('tc1', AgentActivityStatus.done)),
    ]);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(updates.last, isA<ChatSendFailure>());
  });

  test('non-text modality is rejected before spawning', () async {
    final service = _FakeAcp.single(const []);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('draw a cat'),
          modality: PlaygroundModality.image,
        )
        .toList();

    expect(updates.single, isA<ChatSendFailure>());
    expect(service.startCount, 0);
  });

  test(
    'every turn is sent under the mode showing in the composer — changing it '
    'lands on the next message, not the next session',
    () async {
      final service = _FakeAcp([
        [const HermesAcpMessage('a')],
        [const HermesAcpMessage('b')],
      ]);
      final container = _container(service, tmp);
      final sender = container.read(hermesChatSenderProvider);

      await sender
          .send(
            network: _credential(),
            model: 'm',
            conversationId: 'c1',
            history: _history('hi'),
          )
          .toList();

      container
          .read(chatPrefsProvider.notifier)
          .setApproval(AgentApprovalMode.full);

      await sender
          .send(
            network: _credential(),
            model: 'm',
            conversationId: 'c1',
            history: const [
              ChatMessage(role: ChatRole.user, text: 'hi'),
              ChatMessage(role: ChatRole.assistant, text: 'a'),
              ChatMessage(role: ChatRole.user, text: 'now do it'),
            ],
          )
          .toList();

      // Same (reused) session, but the second turn ran under the new mode.
      expect(service.startCount, 1);
      expect(service.sessions.single.modes, [
        AgentApprovalMode.ask,
        AgentApprovalMode.full,
      ]);
    },
  );

  test('the agent asking to run a command stalls the turn and puts it to the '
      'user; their answer goes back down the same session', () async {
    final service = _LiveAcp();
    final container = _container(service, tmp);

    final updates = <ChatSendUpdate>[];
    final finished = container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'm',
          history: _history('clean the build folder'),
        )
        .listen(updates.add)
        .asFuture<void>();

    // Mid-turn, the agent asks. It's now in front of the user, and the turn is
    // still open — nothing ran.
    await _untilListening(service);
    service.session.events.add(const HermesAcpPermission(_permission));
    await pumpEventQueue();
    expect(container.read(agentPermissionProvider)?.command, 'rm -rf build');
    expect(service.session.answers, isEmpty);

    container
        .read(agentPermissionProvider.notifier)
        .answer(AgentPermissionChoice.allowOnce);
    expect(service.session.answers, [(7, 'allow_once')]);

    service.session.finish('Cleaned it.');
    await finished;

    // The turn is over: nothing is left waiting on an answer.
    expect(container.read(agentPermissionProvider), isNull);
    expect((updates.last as ChatSendSuccess).reply.text, 'Cleaned it.');
  });

  test('a stopped turn takes its unanswered question with it', () async {
    final service = _LiveAcp();
    final container = _container(service, tmp);

    final sub = container
        .read(hermesChatSenderProvider)
        .send(network: _credential(), model: 'm', history: _history('go'))
        .listen((_) {});

    await _untilListening(service);
    service.session.events.add(const HermesAcpPermission(_permission));
    await pumpEventQueue();
    expect(container.read(agentPermissionProvider), isNotNull);

    // The user hit stop.
    await sub.cancel();
    await pumpEventQueue();

    expect(container.read(agentPermissionProvider), isNull);
    expect(service.session.answers, isEmpty);
  });
}
