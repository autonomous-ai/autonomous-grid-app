import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_permissions.dart';
import 'package:grid_app/features/agents/logic/agent_steering.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/agent_server_error.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_chat_sender.dart';
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

/// A service whose session start hangs until the test lets it go, so a test can
/// inspect the shared feed while a turn is still in its awaited setup — before the
/// session has opened and before any turn event has fired.
class _HangingStartAcp implements HermesAcpService {
  final _gate = Completer<HermesAcpSession>();
  var startCalled = false;

  @override
  Future<HermesAcpSession> start({required String workdir}) {
    startCalled = true;
    return _gate.future;
  }

  /// Let the hung start finish (with an empty, immediately-closing turn) so the
  /// turn and its subscription can unwind at teardown instead of hanging on the
  /// gate forever.
  void release() {
    if (!_gate.isCompleted) {
      _gate.complete(_FakeAcpSession(const [[]], 'sess-hang'));
    }
  }
}

class _FakeAcpSession implements HermesAcpSession {
  _FakeAcpSession(this._turns, this.sessionId);

  final List<List<HermesAcpEvent>> _turns;
  final prompts = <String>[];

  /// What was handed to a turn already running, in order.
  final steers = <String>[];
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
  Future<String?> steer(String text) async {
    steers.add(text);
    return null;
  }

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

  /// What was handed to the turn while it ran, in order.
  final steers = <String>[];

  /// The raw reason the next steer is refused with, or null to take it.
  String? refuseSteer;

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

  @override
  Future<String?> steer(String text) async {
    if (refuseSteer != null) return refuseSteer;
    steers.add(text);
    return null;
  }

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

ProviderContainer _container(
  HermesAcpService? service,
  Directory tmp, {
  Duration? idleTimeout,
}) {
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
      // Shrink the hung-turn watch so the test doesn't wait minutes for it.
      if (idleTimeout != null)
        agentTurnIdleTimeoutProvider.overrideWithValue(idleTimeout),
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

/// These sends carry no conversation id, so everything they publish is filed
/// under the empty key — runs and permission requests are per chat now.
const _noChat = '';

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
    final steps = container.read(agentRunProvider(_noChat)).steps;
    expect(steps, hasLength(1));
    expect(steps.single.status, AgentActivityStatus.done);
    // Pointed Hermes at the grid.
    expect(File('${tmp.path}/.hermes/config.yaml').existsSync(), isTrue);
  });

  test(
    'a turn that goes silent is left alone — the app does not end a turn the '
    'agent has not ended, and a long install looks exactly like a hang',
    () async {
      final service = _LiveAcp();
      final container = _container(
        service,
        tmp,
        idleTimeout: const Duration(milliseconds: 40),
      );

      final updates = <ChatSendUpdate>[];
      final finished = container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'm',
            history: _history('move the files and start the server'),
          )
          .listen(updates.add)
          .asFuture<void>();

      await _untilListening(service);
      service.session.events.add(
        HermesAcpActivity(_step('mv', AgentActivityStatus.done)),
      );

      // Well past the idle window, and the turn is still running: no failure
      // has been put in the chat and the stream is still open.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(updates.whereType<ChatSendFailure>(), isEmpty);

      // It ends when the agent ends it — or when the user presses Stop.
      service.session.finish('Moved them and started the server.');
      await finished;
      expect(updates.last, isA<ChatSendSuccess>());
    },
  );

  test('while the turn runs the chat can hand it what the user typed; once it '
      'ends there is nobody left to take it', () async {
    final service = _LiveAcp();
    final container = _container(service, tmp);

    final finished = container
        .read(hermesChatSenderProvider)
        .send(network: _credential(), model: 'm', history: _history('go'))
        .listen((_) {})
        .asFuture<void>();

    await _untilListening(service);
    final steering = container.read(agentSteeringProvider.notifier);
    expect(container.read(agentSteeringProvider), contains(_noChat));
    expect(await steering.steer(_noChat, 'just the main file'), isTrue);
    expect(service.session.steers, ['just the main file']);

    service.session.finish('Only the main file, then.');
    await finished;

    // The turn is over: what is typed now belongs to the next one, and the
    // chat's queue is the only thing that can hold it.
    expect(container.read(agentSteeringProvider), isEmpty);
    expect(await steering.steer(_noChat, 'and the tests'), isFalse);
    expect(service.session.steers, ['just the main file']);
  });

  test('a pending permission is the user’s time, not a hang — the idle watch '
      'does not fire while a card is waiting to be answered', () async {
    final service = _LiveAcp();
    final container = _container(
      service,
      tmp,
      idleTimeout: const Duration(milliseconds: 40),
    );

    final updates = <ChatSendUpdate>[];
    final finished = container
        .read(hermesChatSenderProvider)
        .send(network: _credential(), model: 'm', history: _history('go'))
        .listen(updates.add)
        .asFuture<void>();

    await _untilListening(service);
    service.session.events.add(const HermesAcpPermission(_permission));
    await pumpEventQueue();
    // Sit on the card well past the idle window — a user reading a prompt is
    // not the agent hanging, so the turn must still be waiting, not failed.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      container.read(agentPermissionProvider(_noChat))?.command,
      'rm -rf build',
    );
    expect(updates.whereType<ChatSendFailure>(), isEmpty);

    // Answering lets it finish normally.
    container
        .read(agentPermissionsProvider.notifier)
        .answer(_noChat, AgentPermissionChoice.allowOnce);
    service.session.finish('Done.');
    await finished;
    expect((updates.last as ChatSendSuccess).reply.text, 'Done.');
  });

  test(
    'a starting turn empties the shared feed up front — before the session even '
    'opens — so the working bubble never flashes the last turn’s steps',
    () async {
      final service = _HangingStartAcp();
      final container = _container(service, tmp);

      // A prior turn (or another chat) left steps, a citation and a plan behind
      // in the one app-wide feed the working bubble reads.
      final runs = container.read(agentRunsProvider.notifier);
      runs.upsertStep(_noChat, _step('stale', AgentActivityStatus.done));
      runs.addSources(_noChat, const [
        WebSource(title: 'old', url: 'https://old.example'),
      ]);
      runs.setPlan(_noChat, const [
        AgentPlanEntry(content: 'old', status: AgentPlanStatus.pending),
      ]);

      final sub = container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('hi'))
          .listen((_) {});
      // LIFO: release the gate first so the async turn unwinds, then cancel — a
      // cancel while it's still hung on the gate would never complete.
      addTearDown(sub.cancel);
      addTearDown(service.release);

      // Let the send run up to the hanging session start — point-at-grid writes
      // config first, which is real file I/O, so drain generously (as
      // [_untilListening] does).
      for (var i = 0; i < 500 && !service.startCalled; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        service.startCalled,
        isTrue,
        reason: 'setup never reached session start',
      );

      // The session hasn’t opened and no turn event has fired, yet the feed is
      // already empty: it was cleared up front, not once the turn body ran. Were
      // the reset back in the turn body (after this await), the stale entries
      // would still be here.
      final run = container.read(agentRunProvider(_noChat));
      expect(run.steps, isEmpty);
      expect(run.sources, isEmpty);
      expect(run.plan, isEmpty);
    },
  );

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
      expect(
        container.read(agentRunProvider(_noChat)).sources.map((s) => s.url),
        ['https://flutter.dev', 'https://dart.dev'],
      );
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
      expect(container.read(agentRunProvider(_noChat)).plan, hasLength(2));
    },
  );

  test(
    'a turn that fails with an error the app understands says what went wrong, '
    'not that the agent had nothing to say',
    () async {
      // What Hermes answers a prompt with when it can't resolve the model the
      // app pointed it at (a responses-only model on a build that reads no
      // named provider). Nothing streams, so this used to land as "the agent
      // didn't return an answer" — a sentence about the agent, for a problem
      // with the connection.
      final service = _FakeAcp.single([
        const HermesAcpTurnEnded(
          '',
          error:
              "Internal error: No LLM provider configured. Run `hermes "
              'model` to select a provider.',
        ),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('go'))
          .toList();

      expect(updates.last, isA<ChatSendFailure>());
      expect((updates.last as ChatSendFailure).error, kAgentProviderUnknown);
    },
  );

  test('a turn that errors for a reason nobody has a line for still reads as a '
      'failed turn, never as an agent with nothing to say', () async {
    final service = _FakeAcp.single([
      const HermesAcpTurnEnded('', error: 'Internal error: something odd'),
    ]);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(network: _credential(), model: 'm', history: _history('go'))
        .toList();

    final failure = updates.last as ChatSendFailure;
    expect(failure.error, kAgentTurnFailed);
    expect(failure.error, isNot(kAgentNoAnswer));
  });

  test('a message that never reached the assistant says the connection went, '
      'not that the model let the user down', () async {
    final service = _FakeAcp.single([
      const HermesAcpTurnEnded(
        'cancelled',
        error: '$kAcpLostContact: SocketException: broken pipe',
      ),
    ]);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(network: _credential(), model: 'm', history: _history('go'))
        .toList();

    final failure = updates.last as ChatSendFailure;
    expect(failure.error, kAgentLostContact);
    // The lever is sending again, not the model picker — and the raw pipe error
    // belongs in the log, never in the chat.
    expect(failure.error, isNot(contains('model')));
    expect(failure.error, isNot(contains('SocketException')));
  });

  test(
    'a turn that lays out a plan and then does nothing about it still shows '
    'what it said — the unticked box goes to the log, not over the answer',
    () async {
      final service = _FakeAcp.single([
        const HermesAcpPlan([
          AgentPlanEntry(content: 'Read', status: AgentPlanStatus.done),
          // Left hanging: the work it promised didn't happen.
          AgentPlanEntry(content: 'Write', status: AgentPlanStatus.pending),
        ]),
        const HermesAcpMessage('Let me write it for you.'),
        const HermesAcpTurnEnded('end_turn'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('go'))
          .toList();

      // The app doesn't overrule the agent about its own work: whatever it
      // said is what the user reads, and the unfinished plan is a line in the
      // log for whoever is diagnosing it.
      expect(updates.last, isA<ChatSendSuccess>());
      expect(
        (updates.last as ChatSendSuccess).reply.text,
        'Let me write it for you.',
      );
    },
  );

  test(
    'a turn that works through its plan and answers is an answer, even with a '
    'step left unticked',
    () async {
      final service = _FakeAcp.single([
        const HermesAcpPlan([
          AgentPlanEntry(
            content: 'Read the thread',
            status: AgentPlanStatus.done,
          ),
          AgentPlanEntry(
            content: 'Summarize it',
            status: AgentPlanStatus.active,
          ),
        ]),
        // The work the plan promised, after the plan — a model that then answers
        // in full but never ticks the last box has not stalled.
        const HermesAcpActivity(
          AgentActivity(
            id: 't1',
            kind: AgentActivityKind.command,
            label: 'read the comments',
            status: AgentActivityStatus.done,
          ),
        ),
        const HermesAcpMessage('All 51 comments, by theme: …'),
        const HermesAcpTurnEnded('end_turn'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('go'))
          .toList();

      expect(updates.last, isA<ChatSendSuccess>());
      final reply = (updates.last as ChatSendSuccess).reply;
      expect(reply.text, 'All 51 comments, by theme: …');
      // The unticked step still rides on the answer, so the gap is visible
      // without the app calling a finished turn a failure.
      expect(reply.plan.last.status, AgentPlanStatus.active);
    },
  );

  test(
    'a turn that ticks its boxes on the way out still answered — the work came '
    'before the closing plan revision',
    () async {
      // The order that had a finished review reported as a stall: all the work
      // first, one closing plan revision, then the answer. Counting only work
      // *since* the last revision, the agent's own book-keeping erased every
      // command it had just run.
      final service = _FakeAcp.single([
        const HermesAcpActivity(
          AgentActivity(
            id: 't1',
            kind: AgentActivityKind.command,
            label: 'flutter analyze',
            status: AgentActivityStatus.done,
          ),
        ),
        const HermesAcpPlan([
          AgentPlanEntry(
            content: 'Read the diff',
            status: AgentPlanStatus.done,
          ),
          AgentPlanEntry(
            content: 'Write the review',
            status: AgentPlanStatus.active,
          ),
        ]),
        const HermesAcpMessage('The review, in full: …'),
        const HermesAcpTurnEnded('end_turn'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('review'))
          .toList();

      expect(updates.last, isA<ChatSendSuccess>());
      expect(
        (updates.last as ChatSendSuccess).reply.text,
        'The review, in full: …',
      );
    },
  );

  test(
    'a turn cut short mid-plan is a stall however much work it got through',
    () async {
      final service = _FakeAcp.single([
        const HermesAcpPlan([
          AgentPlanEntry(content: 'Read', status: AgentPlanStatus.done),
          AgentPlanEntry(content: 'Write', status: AgentPlanStatus.active),
        ]),
        const HermesAcpActivity(
          AgentActivity(
            id: 't1',
            kind: AgentActivityKind.command,
            label: 'write the file',
            status: AgentActivityStatus.running,
          ),
        ),
        const HermesAcpMessage('Writing it now…'),
        // Out of room, not done: the step it was on never landed.
        const HermesAcpTurnEnded('max_tokens'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(network: _credential(), model: 'm', history: _history('go'))
          .toList();

      // Cut off mid-step by the model's own limit — still the agent's turn to
      // report, and it reported words.
      expect(updates.last, isA<ChatSendSuccess>());
      expect((updates.last as ChatSendSuccess).reply.text, 'Writing it now…');
    },
  );

  test(
    'in planning mode an unfinished plan is the point, not a stall — the plan '
    'lands as the answer',
    () async {
      final service = _FakeAcp.single([
        const HermesAcpPlan([
          AgentPlanEntry(content: 'Read', status: AgentPlanStatus.pending),
          AgentPlanEntry(content: 'Write', status: AgentPlanStatus.pending),
        ]),
        const HermesAcpMessage('Here is my plan…'),
      ]);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'm',
            history: _history('refactor the parser'),
            planFirst: true,
          )
          .toList();

      expect(updates.last, isA<ChatSendSuccess>());
      expect((updates.last as ChatSendSuccess).reply.text, 'Here is my plan…');
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
    // the whole history re-flattened. The agent wrote 'hi there' itself, so it
    // is never quoted back at it.
    expect(service.prompts, ['hello', 'thanks']);
  });

  // A turn carrying a picture is answered by the grid's API, never the agent
  // (see `agentAnswersTurn`), so it lands in the chat with no agent turn behind
  // it. Sending only the newest message left the agent confidently discussing a
  // conversation it had half of.
  test(
    'a turn the agent never handled is carried into its next turn',
    () async {
      final service = _FakeAcp([
        [const HermesAcpMessage('hi there')],
        [const HermesAcpMessage('a tabby')],
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

      await sender
          .send(
            network: _credential(),
            model: 'm',
            conversationId: 'conv-1',
            history: const [
              ChatMessage(role: ChatRole.user, text: 'hello'),
              ChatMessage(role: ChatRole.assistant, text: 'hi there'),
              // These two went to the grid, not the agent.
              ChatMessage(role: ChatRole.user, text: 'look at this picture'),
              ChatMessage(role: ChatRole.assistant, text: 'I see a cat.'),
              ChatMessage(role: ChatRole.user, text: 'what breed?'),
            ],
          )
          .toList();

      expect(service.startCount, 1);
      final second = service.prompts.last;
      expect(second, contains('look at this picture'));
      expect(second, contains('I see a cat.'));
      expect(second, endsWith('what breed?'));
      // Still not the agent's own reply from turn one — it already has that.
      expect(second, isNot(contains('hi there')));
    },
  );

  test('switching conversation starts a fresh session, and leaves the one it '
      'came from open', () async {
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
    // Each chat keeps its own. Closing the one being left meant flipping between
    // two conversations replayed the whole history on every single turn.
    expect(service.sessions.first.isClosed, isFalse);
  });

  test(
    'going back to a chat resumes its session rather than respawning',
    () async {
      final service = _FakeAcp([
        [const HermesAcpMessage('a')],
        [const HermesAcpMessage('b')],
      ]);
      final container = _container(service, tmp);
      final sender = container.read(hermesChatSenderProvider);

      Future<void> turn(String conv, List<ChatMessage> history) => sender
          .send(
            network: _credential(),
            model: 'm',
            conversationId: conv,
            history: history,
          )
          .toList();

      await turn('conv-1', _history('one'));
      await turn('conv-2', _history('two'));
      await turn('conv-1', const [
        ChatMessage(role: ChatRole.user, text: 'one'),
        ChatMessage(role: ChatRole.assistant, text: 'a'),
        ChatMessage(role: ChatRole.user, text: 'again'),
      ]);

      // Two chats, two processes — the third turn reused conv-1's.
      expect(service.startCount, 2);
      expect(service.sessions.first.prompts, ['one', 'again']);
    },
  );

  test('past the cap the least recently used session is closed', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('a')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    // One conversation more than the cap allows.
    for (var i = 0; i <= kMaxLiveAgentSessions; i++) {
      await sender
          .send(
            network: _credential(),
            model: 'm',
            conversationId: 'conv-$i',
            history: _history('hello $i'),
          )
          .toList();
    }

    expect(service.startCount, kMaxLiveAgentSessions + 1);
    expect(
      service.sessions.first.isClosed,
      isTrue,
      reason: 'the oldest chat gave up its process',
    );
    expect(service.sessions.last.isClosed, isFalse);
    // Exactly one was evicted — the cap is a ceiling, not a stampede.
    expect(service.sessions.where((s) => s.isClosed).length, 1);
  });

  test('disposing the sender kills every live session', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('a')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider) as HermesChatSender;

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

    await sender.dispose();

    expect(service.sessions.every((s) => s.isClosed), isTrue);
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
    'a startup that retrying cannot fix is humanized, and does not say to retry',
    () async {
      // The real shape of this: hermes-agent installed without its `[acp]` extra,
      // so `hermes acp` dies on startup with a pip command. The user runs Grid,
      // not a terminal, so the chat must not show that raw reason (it's logged
      // instead) and must not tell them to retry a fault that never changes.
      final container = _container(
        _FailingAcp(
          const HermesAcpException(
            "Hermes exited during startup: ACP dependencies not installed. "
            "Install them with: pip install -e '.[acp]'",
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
      expect(error.toLowerCase(), isNot(contains('pip')));
      expect(error.toLowerCase(), isNot(contains('acp')));
      expect(error.toLowerCase(), contains('agents'));
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

  test('every turn is sent under the mode showing in the composer — changing it '
      'lands on the next message, not the next session', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('a')],
      [const HermesAcpMessage('b')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    // Start on Ask so the switch below is the only thing that can move the
    // second turn's mode — the point of the test, whatever the shipped default.
    container
        .read(chatPrefsProvider.notifier)
        .setApproval(AgentApprovalMode.ask);

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
  });

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
    expect(
      container.read(agentPermissionProvider(_noChat))?.command,
      'rm -rf build',
    );
    expect(service.session.answers, isEmpty);

    container
        .read(agentPermissionsProvider.notifier)
        .answer(_noChat, AgentPermissionChoice.allowOnce);
    expect(service.session.answers, [(7, 'allow_once')]);

    service.session.finish('Cleaned it.');
    await finished;

    // The turn is over: nothing is left waiting on an answer.
    expect(container.read(agentPermissionProvider(_noChat)), isNull);
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
    expect(container.read(agentPermissionProvider(_noChat)), isNotNull);

    // The user hit stop.
    await sub.cancel();
    await pumpEventQueue();

    expect(container.read(agentPermissionProvider(_noChat)), isNull);
    expect(service.session.answers, isEmpty);
  });
}
