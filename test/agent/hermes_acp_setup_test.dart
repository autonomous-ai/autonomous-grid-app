import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_setup.dart';

/// A [HermesAcpSetup] whose repair is scripted, recording whether it was asked —
/// no `uv` runs, nothing is installed.
class _FakeSetup implements HermesAcpSetup {
  _FakeSetup({this.failure});

  /// What `hermes acp --check` would say — false until a repair succeeds.
  bool ready = false;

  /// The raw reason a repair fails, or null when it succeeds.
  final String? failure;

  int repairs = 0;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<String?> repair() async {
    repairs++;
    if (failure != null) return failure;
    ready = true;
    return null;
  }

  int webSearchEnsures = 0;

  @override
  Future<void> ensureWebSearch() async => webSearchEnsures++;
}

/// A `hermes acp` that fails with [_error] until [healAfter] starts have gone by
/// — the shape of an install that only works once the missing piece is there.
class _ScriptedAcp implements HermesAcpService {
  _ScriptedAcp(this._error, {this.healAfter = 1});

  final HermesAcpException _error;
  final int healAfter;
  int starts = 0;

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    starts++;
    if (starts <= healAfter) throw _error;
    return _DeadSession();
  }
}

/// The session the scripted service hands back once it starts — never prompted,
/// so every member is a stub.
class _DeadSession implements HermesAcpSession {
  @override
  String? get sessionId => 'sess-1';

  @override
  bool get isClosed => false;

  @override
  set approvalMode(AgentApprovalMode mode) {}

  @override
  HermesAcpRun prompt(String text) => throw UnimplementedError();

  @override
  void answerPermission(Object requestId, String? optionId) {}

  @override
  Future<void> close() async {}
}

const _missingAcp = HermesAcpException(
  "Hermes exited during startup: ACP dependencies not installed. Install them "
  "with: pip install -e '.[acp]'",
  retryable: false,
);

void main() {
  group('what a repair asks for', () {
    test('installs Hermes *with* the extra ACP needs — without it the binary '
        'runs and the agent cannot answer at all', () {
      expect(kHermesAcpRequirement, 'hermes-agent[acp]');
      expect(hermesAcpRepairArgs(), contains(kHermesAcpRequirement));
      // Pinned to the interpreter the CLI installed Hermes on, so the repair
      // lands in that environment instead of building a second one.
      expect(hermesAcpRepairArgs(), containsAllInOrder(['--python', '3.13']));
    });

    test('keeps everything it installs inside ~/.grid, so the repair fixes the '
        'Hermes on PATH rather than adding a second one elsewhere', () {
      final env = hermesAcpRepairEnv(gridHome: '/tmp/grid-home');

      expect(env['UV_TOOL_BIN_DIR'], '/tmp/grid-home/bin');
      expect(env['UV_TOOL_DIR'], '/tmp/grid-home/tools');
      expect(env['UV_PYTHON_INSTALL_DIR'], '/tmp/grid-home/python');
    });
  });

  group('ensuring a keyless web-search backend', () {
    test('installs the free ddgs package into the very interpreter Hermes runs '
        'on, so its native web_search has a provider', () {
      final args = hermesWebSearchInstallArgs('/g/tools/hermes-agent/bin/python');
      expect(kHermesWebSearchPackage, 'ddgs');
      expect(args, containsAllInOrder(['pip', 'install']));
      // Pinned to Hermes's own interpreter — a backend in any other environment
      // is one its web_search tool can't import.
      expect(
        args,
        containsAllInOrder([
          '--python',
          '/g/tools/hermes-agent/bin/python',
          'ddgs',
        ]),
      );
      // Not --force: a fast no-op once ddgs is already there.
      expect(args, isNot(contains('--force')));
    });
  });

  group('recognising a half-finished install', () {
    test('Hermes saying its ACP dependencies are absent is one', () {
      expect(
        isAcpSetupIncomplete(
          "ACP dependencies not installed. Install them with: pip install -e "
          "'.[acp]'",
        ),
        isTrue,
      );
    });

    test('so is the Python import error the same state produces', () {
      expect(
        isAcpSetupIncomplete("ModuleNotFoundError: No module named 'acp'"),
        isTrue,
      );
    });

    test('a crash that installing cannot fix is not — repairing it would waste '
        'the user\'s time and still fail', () {
      expect(isAcpSetupIncomplete('RuntimeError: something obscure'), isFalse);
      expect(
        isAcpSetupIncomplete('Hermes could not start: spawn failed'),
        isFalse,
      );
    });
  });

  group('starting a session on a half-installed Hermes', () {
    test('finishes the install and comes back with a working session, instead '
        'of failing the turn', () async {
      final acp = _ScriptedAcp(_missingAcp);
      final setup = _FakeSetup();

      final session = await RepairingHermesAcpService(
        acp,
        setup,
      ).start(workdir: '/tmp');

      expect(session.sessionId, 'sess-1');
      expect(setup.repairs, 1);
      expect(acp.starts, 2, reason: 'retried once the piece was installed');
    });

    test('a repair that fails carries its raw reason on for the log, and does '
        'not invite a retry that fails identically', () async {
      final acp = _ScriptedAcp(_missingAcp, healAfter: 99);
      final setup = _FakeSetup(failure: 'uv: could not reach pypi.org');

      await expectLater(
        RepairingHermesAcpService(acp, setup).start(workdir: '/tmp'),
        throwsA(
          isA<HermesAcpException>()
              .having((e) => e.message, 'message', contains('pypi.org'))
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      expect(acp.starts, 1, reason: 'no point starting it again unrepaired');
    });

    test('a failure installing cannot fix is passed straight on, untouched by '
        'a pointless repair', () async {
      final acp = _ScriptedAcp(
        const HermesAcpException('Hermes could not start: spawn failed'),
        healAfter: 99,
      );
      final setup = _FakeSetup();

      await expectLater(
        RepairingHermesAcpService(acp, setup).start(workdir: '/tmp'),
        throwsA(
          isA<HermesAcpException>()
              .having((e) => e.message, 'message', contains('spawn failed'))
              // Still retryable: this one might work next time.
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      expect(setup.repairs, 0);
    });
  });
}
