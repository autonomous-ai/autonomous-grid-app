import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_server_error.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_install_controller.dart';
import 'package:grid_app/infrastructure/cli/agent_spec_installer.dart';
import 'package:grid_app/infrastructure/cli/claude_installer.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_setup.dart';
import 'package:grid_app/infrastructure/cli/hermes_version_service.dart';

/// The recipe runner, recorded rather than run — nothing is downloaded and no
/// process is spawned.
class _FakeSpecInstaller implements AgentSpecInstaller {
  _FakeSpecInstaller({this.failure});

  /// What the run throws, or null when it succeeds.
  final AgentInstallException? failure;

  final ran = <AgentInstallSpec>[];

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    void Function(String line)? onLog,
  }) async {
    ran.add(spec);
    if (failure != null) throw failure!;
  }
}

/// Hermes's ACP support as the test wants to find it — no `hermes acp --check`
/// runs and no `uv` installs anything.
class _FakeSetup implements HermesAcpSetup {
  _FakeSetup({this.ready = true, this.failure});

  bool ready;

  /// The raw reason a repair fails, or null when it works.
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

/// Claude Code's vendor installer, recorded rather than run — no download, and
/// nothing written to the machine running the tests.
class _FakeClaudeInstaller implements ClaudeInstaller {
  _FakeClaudeInstaller({this.failure});

  /// What the installer reports back, or null when it worked.
  final String? failure;
  final upgrades = <bool>[];

  @override
  Future<String?> install({required bool upgrade}) async {
    upgrades.add(upgrade);
    return failure;
  }
}

ProviderContainer _container({
  AgentSpecInstaller? specs,
  HermesAcpSetup? setup,
  ClaudeInstaller? claude,
}) {
  final container = ProviderContainer(
    overrides: [
      agentSpecInstallerProvider.overrideWithValue(
        specs ?? _FakeSpecInstaller(),
      ),
      // Never probe the real Hermes on the machine running the tests.
      hermesAcpSetupProvider.overrideWithValue(setup ?? _FakeSetup()),
      claudeInstallerProvider.overrideWithValue(
        claude ?? _FakeClaudeInstaller(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('installing an agent', () {
    test('runs the agent\'s own recipe and ends on the outcome the button '
        'shows, not back at idle', () async {
      final specs = _FakeSpecInstaller();
      final container = _container(specs: specs);
      final controller = container.read(agentInstallProvider.notifier);

      await controller.install(AgentTool.hermes);

      expect(specs.ran.single, isA<UvToolInstall>());
      expect(container.read(agentInstallProvider), isA<AgentInstallDone>());
    });

    test('Claude Code goes to its vendor installer instead — it ships one, and '
        'knows its own release channel', () async {
      final specs = _FakeSpecInstaller();
      final claude = _FakeClaudeInstaller();
      final container = _container(specs: specs, claude: claude);
      final controller = container.read(agentInstallProvider.notifier);

      await controller.install(AgentTool.claude);
      expect(claude.upgrades, [false]);
      expect(specs.ran, isEmpty);
      expect(container.read(agentInstallProvider), isA<AgentInstallDone>());

      await controller.install(AgentTool.claude, upgrade: true);
      expect(claude.upgrades, [false, true]);
    });

    test('a failed Claude install keeps the installer own reason, so a proxy '
        'or a missing curl is diagnosable', () async {
      final container = _container(
        claude: _FakeClaudeInstaller(failure: 'curl: (6) Could not resolve'),
      );

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.claude);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.tool, AgentTool.claude);
      expect(state.message, contains('Could not resolve'));
    });

    test("a failure comes back as the installer's own last words, not an exit "
        'code', () async {
      final container = _container(
        specs: _FakeSpecInstaller(
          failure: const AgentInstallException('no space left on device'),
        ),
      );

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains('no space left on device'));
      expect(state.tool, AgentTool.hermes);
    });

    test('a crash that said nothing still says what to do', () async {
      final container = _container(
        specs: _FakeSpecInstaller(failure: const AgentInstallException('')),
      );

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, isNotEmpty);
    });

    test(
      'an install that left Hermes unable to serve ACP is finished off, so '
      'the row never reads "installed" for an agent chat cannot use',
      () async {
        final setup = _FakeSetup(ready: false);
        final container = _container(setup: setup);

        await container
            .read(agentInstallProvider.notifier)
            .install(AgentTool.hermes, upgrade: true);

        expect(setup.repairs, 1);
        expect(setup.ready, isTrue);
        expect(container.read(agentInstallProvider), isA<AgentInstallDone>());
      },
    );

    test(
      'an agent that already works is not reinstalled a second time',
      () async {
        final setup = _FakeSetup();
        final container = _container(setup: setup);

        await container
            .read(agentInstallProvider.notifier)
            .install(AgentTool.hermes);

        expect(setup.repairs, 0);
      },
    );

    test('the optional tools are topped up even when ACP already works — a '
        'reinstall rebuilds the environment and drops what the app added, '
        'leaving web search and every connector silently dead', () async {
      final setup = _FakeSetup();
      final container = _container(setup: setup);

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes, upgrade: true);

      expect(setup.runtimeTopUps, 1);
    });

    test('a repair that could not run says so, rather than reporting an '
        'install that answers nothing', () async {
      final container = _container(
        setup: _FakeSetup(
          ready: false,
          failure: 'uv: could not reach pypi.org',
        ),
      );

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains(kAgentSetupUnfinished));
      // The raw reason belongs in the log, not in front of the user.
      expect(state.message, isNot(contains('pypi.org')));
    });
  });

  group('the catalog', () {
    test('lists only agents the app can install, so no row on the screen is '
        'there to be looked at rather than used', () {
      expect(AgentTool.values, [
        AgentTool.hermes,
        AgentTool.codex,
        AgentTool.claude,
        AgentTool.pi,
      ]);
      expect(kChatAgent, AgentTool.hermes);
    });

    test('every agent on it can actually be fetched — a recipe of the app\'s '
        'own, or a vendor installer for the one that ships one', () {
      expect(AgentTool.hermes.installSpec, isA<UvToolInstall>());
      expect(AgentTool.codex.installSpec, isA<GithubReleaseBinary>());
      expect(AgentTool.claude.installSpec, isNull);
      expect(AgentTool.pi.installSpec, isA<NodeToolInstall>());
    });
  });

  group('parseHermesVersion', () {
    test('reads the build out of what Hermes prints', () {
      expect(
        parseHermesVersion(
          'Hermes Agent v0.18.2 (2026.7.7.2) · upstream 861d69c7\n'
          'Install directory: /Users/x/.hermes/hermes-agent\n',
        ),
        '0.18.2',
      );
    });

    test('a binary that answers with something else reads as unknown, not as a '
        'stray line on the screen', () {
      expect(parseHermesVersion('command not found'), isNull);
      expect(parseHermesVersion(''), isNull);
    });
  });
}
