import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/agent_registry.dart';
import 'package:grid_app/features/agent/common/agent_server_error.dart';
import 'package:grid_app/features/agent/hermes/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_install_controller.dart';
import 'package:grid_app/infrastructure/cli/agent_installer.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_setup.dart';
import 'package:grid_app/infrastructure/cli/hermes_version_service.dart';

/// Records the specs it was asked to install and answers with success — or a
/// canned failure — so the controller is tested without touching the network or
/// the disk.
class _FakeInstaller implements AgentInstaller {
  _FakeInstaller({this.error});

  /// Thrown on every run when set, so a failure path can be exercised.
  final Object? error;
  final specs = <AgentInstallSpec>[];

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    bool upgrade = false,
    void Function(String line)? onLog,
  }) async {
    specs.add(spec);
    if (error != null) throw error!;
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
}

ProviderContainer _container({
  AgentInstaller? installer,
  HermesAcpSetup? setup,
}) {
  final container = ProviderContainer(
    overrides: [
      agentInstallerProvider.overrideWithValue(installer ?? _FakeInstaller()),
      // Never probe the real Hermes on the machine running the tests.
      hermesAcpSetupProvider.overrideWithValue(setup ?? _FakeSetup()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final hermes = agentById('hermes')!;
  final codex = agentById('codex')!;

  group('installing an agent', () {
    test('runs the agent\'s own install recipe, no grid CLI', () async {
      final installer = _FakeInstaller();
      final container = _container(installer: installer);

      await container.read(agentInstallProvider.notifier).install(hermes);

      // Hermes is a uv tool; Codex a release binary — each carries its own recipe.
      expect(installer.specs.single, isA<UvToolInstall>());
      expect(
        (installer.specs.single as UvToolInstall).package,
        'hermes-agent[acp]',
      );
      expect(container.read(agentInstallProvider), isA<AgentInstallIdle>());
    });

    test('Codex installs from its release binary', () async {
      final installer = _FakeInstaller();
      final container = _container(installer: installer);

      await container.read(agentInstallProvider.notifier).install(codex);

      expect(installer.specs.single, isA<GithubReleaseBinary>());
      expect(
        (installer.specs.single as GithubReleaseBinary).executable,
        'codex',
      );
    });

    test('a failure comes back as a line the user can act on', () async {
      final container = _container(
        installer: _FakeInstaller(
          error: const AgentInstallException('could not reach github.com'),
        ),
      );

      await container.read(agentInstallProvider.notifier).install(hermes);

      final state = container.read(agentInstallProvider);
      expect(state, isA<AgentInstallFailed>());
      expect(
        (state as AgentInstallFailed).message,
        contains('could not reach github.com'),
      );
      expect(state.agent, hermes);
    });

    test('a transient failure invites a retry', () async {
      final container = _container(
        installer: _FakeInstaller(
          error: const AgentInstallException('spawn failed', retryable: true),
        ),
      );

      await container.read(agentInstallProvider.notifier).install(hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains('try'));
    });

    test('an install left unable to serve ACP is finished off, so the row '
        'never reads "installed" for an agent chat cannot use', () async {
      final setup = _FakeSetup(ready: false);
      final container = _container(setup: setup);

      await container
          .read(agentInstallProvider.notifier)
          .install(hermes, upgrade: true);

      expect(setup.repairs, 1);
      expect(setup.ready, isTrue);
      expect(container.read(agentInstallProvider), isA<AgentInstallIdle>());
    });

    test('an agent that already works is not repaired a second time', () async {
      final setup = _FakeSetup();
      final container = _container(setup: setup);

      await container.read(agentInstallProvider.notifier).install(hermes);

      expect(setup.repairs, 0);
    });

    test('a repair that could not run says so, rather than reporting an '
        'install that answers nothing', () async {
      final container = _container(
        setup: _FakeSetup(
          ready: false,
          failure: 'uv: could not reach pypi.org',
        ),
      );

      await container.read(agentInstallProvider.notifier).install(hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains(kAgentSetupUnfinished));
      // The raw reason belongs in the log, not in front of the user.
      expect(state.message, isNot(contains('pypi.org')));
    });
  });

  group('the catalog', () {
    test('registers the agents this build knows, default first', () {
      expect(kAgents.map((a) => a.id), ['hermes', 'codex', 'openclaw']);
      expect(kDefaultChatAgent, hermes);
    });

    test('a dev-only agent is dropped from a shipped release, not the '
        'default', () {
      // OpenClaw's install path isn't proven out yet, so it is developer-only;
      // the agents that answer today are not.
      expect(agentById('openclaw')!.devOnly, isTrue);
      expect(hermes.devOnly, isFalse);
      expect(codex.devOnly, isFalse);
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
