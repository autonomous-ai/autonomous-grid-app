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

  int runtimeTopUps = 0;

  @override
  Future<void> ensureRuntimeSupport() async => runtimeTopUps++;
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
  Future<String?> steer(String text) async => 'no turn is running';

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
    test('installs Hermes *with* the extras it is mute without — ACP or the '
        'agent cannot answer at all, MCP and every connector it was given is '
        'dropped in silence', () {
      expect(kHermesAcpRequirement, 'hermes-agent[acp,mcp]');
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

    test('forces the ~/.grid tool tree only for a Hermes that lives there — an '
        'install elsewhere gets uv\'s defaults so the repair lands on it, not a '
        'second copy', () {
      expect(
        hermesAcpRepairEnvFor(
          hermesPath: '/home/u/.grid/bin/hermes',
          gridHome: '/home/u/.grid',
        ),
        hermesAcpRepairEnv(gridHome: '/home/u/.grid'),
      );
      expect(
        hermesAcpRepairEnvFor(
          hermesPath: '/home/u/.local/bin/hermes',
          gridHome: '/home/u/.grid',
        ),
        isEmpty,
      );
    });
  });

  group('finding a uv to repair with', () {
    test('prefers the CLI\'s own ~/.grid copy but also knows the uv-tool and '
        'Homebrew locations — a legacy install\'s uv is rarely in ~/.grid', () {
      final paths = uvCandidatePaths(
        gridHome: '/home/u/.grid',
        home: '/home/u',
      );

      expect(paths.first, '/home/u/.grid/bin/uv');
      expect(
        paths,
        containsAll(<String>[
          '/home/u/.local/bin/uv',
          // The Intel-Mac Homebrew prefix — the machine the broadened search is
          // for.
          '/usr/local/bin/uv',
          '/opt/homebrew/bin/uv',
        ]),
      );
    });
  });

  group('topping up the tools Hermes only imports when asked', () {
    test('covers both silent failures: a web search with no keyless backend, '
        'and MCP servers with no SDK to run them', () {
      // ddgs is the only backend of Hermes's own list that needs no key; mcp is
      // what every `mcp_servers:` entry — every connector — runs on.
      expect(kHermesRuntimePackages.keys, containsAll(['ddgs', 'mcp']));
      // A floor, not a pin: a newer Hermes may install a newer SDK for itself,
      // and topping the environment up must never drag it back.
      expect(kHermesRuntimePackages['mcp'], 'mcp>=1.26,<2');
    });

    test('asks Hermes\'s own interpreter what is missing, so nothing is '
        'installed on a machine that already has it', () {
      final args = hermesRuntimeProbeArgs(['ddgs', 'mcp']);

      expect(args.first, '-c');
      expect(args.last, contains('"ddgs"'));
      expect(args.last, contains('"mcp"'));
      // find_spec, not an import: probing runs before every chat and must not
      // pay for loading the packages it asks about.
      expect(args.last, contains('find_spec'));
    });

    test('installs exactly what the probe reported missing', () {
      expect(hermesMissingRequirements('mcp\n'), ['mcp>=1.26,<2']);
      expect(hermesMissingRequirements('ddgs\nmcp\n'), [
        'ddgs',
        'mcp>=1.26,<2',
      ]);
      // Nothing missing — and the top-up must then run no installer at all.
      expect(hermesMissingRequirements('\n'), isEmpty);
      // A line the interpreter printed for its own reasons is not a package.
      expect(hermesMissingRequirements('warning: something\n'), isEmpty);
    });

    test('adds them to the very interpreter Hermes runs on, without touching '
        'the Hermes build the user already has', () {
      final args = hermesRuntimeInstallArgs(
        '/g/tools/hermes-agent/bin/python',
        ['ddgs'],
      );

      // `pip install`, not `tool install`: the latter re-resolves hermes-agent
      // itself and could move the user to a build they never asked for.
      expect(args, containsAllInOrder(['pip', 'install']));
      expect(
        args,
        containsAllInOrder([
          '--python',
          '/g/tools/hermes-agent/bin/python',
          'ddgs',
        ]),
      );
      // Not --force: a fast no-op if the package turns out to be there.
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
