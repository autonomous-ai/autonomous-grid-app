import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agent/logic/agent_server_error.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_install_controller.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_setup.dart';
import 'package:grid_app/infrastructure/cli/hermes_version_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Records what the app asked the `grid` CLI to do, and answers with a canned
/// result — no process is spawned.
class _FakeCli implements GridCliService {
  _FakeCli({this.exitCode = 0, this.stderr = '', this.stdout = ''});

  final int exitCode;
  final String stderr;
  final String stdout;
  final calls = <List<String>>[];

  @override
  Future<CliResult> run(List<String> args) async {
    calls.add(args);
    return CliResult(exitCode: exitCode, stdout: stdout, stderr: stderr);
  }

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) => throw UnimplementedError();

  @override
  Stream<DownloadProgress> pull(List<String> args) =>
      throw UnimplementedError();
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

  @override
  Future<void> ensureWebSearch() async {}
}

ProviderContainer _container(GridCliService? cli, {HermesAcpSetup? setup}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      // Never probe the real Hermes on the machine running the tests.
      hermesAcpSetupProvider.overrideWithValue(setup ?? _FakeSetup()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('installing an agent', () {
    test(
      'asks the CLI for it by name — and asks to replace it when updating',
      () async {
        final cli = _FakeCli();
        final container = _container(cli);
        final controller = container.read(agentInstallProvider.notifier);

        await controller.install(AgentTool.hermes);
        expect(cli.calls.single, ['agent', 'install', 'hermes']);
        expect(container.read(agentInstallProvider), isA<AgentInstallIdle>());

        await controller.install(AgentTool.hermes, upgrade: true);
        expect(cli.calls.last, ['agent', 'install', 'hermes', '--force']);
      },
    );

    test(
      'a failure comes back as the CLI\'s own last words, not an exit code',
      () async {
        final cli = _FakeCli(
          exitCode: 1,
          stderr: 'error: could not reach github.com',
        );
        final container = _container(cli);

        await container
            .read(agentInstallProvider.notifier)
            .install(AgentTool.hermes);

        final state = container.read(agentInstallProvider);
        expect(state, isA<AgentInstallFailed>());
        expect(
          (state as AgentInstallFailed).message,
          contains('could not reach github.com'),
        );
        expect(state.tool, AgentTool.hermes);
      },
    );

    test(
      'a CLI that complains on stdout instead of stderr is still heard',
      () async {
        final container = _container(
          _FakeCli(exitCode: 1, stdout: 'no space left on device'),
        );

        await container
            .read(agentInstallProvider.notifier)
            .install(AgentTool.hermes);

        final state =
            container.read(agentInstallProvider) as AgentInstallFailed;
        expect(state.message, contains('no space left on device'));
      },
    );

    test('a failure that said nothing still says what to do', () async {
      final container = _container(_FakeCli(exitCode: 2));

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains('try again'));
    });

    test('an install the CLI left unable to serve ACP is finished off, so the '
        'row never reads "installed" for an agent chat cannot use', () async {
      final setup = _FakeSetup(ready: false);
      final container = _container(_FakeCli(), setup: setup);

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes, upgrade: true);

      expect(setup.repairs, 1);
      expect(setup.ready, isTrue);
      expect(container.read(agentInstallProvider), isA<AgentInstallIdle>());
    });

    test(
      'an agent that already works is not reinstalled a second time',
      () async {
        final setup = _FakeSetup();
        final container = _container(_FakeCli(), setup: setup);

        await container
            .read(agentInstallProvider.notifier)
            .install(AgentTool.hermes);

        expect(setup.repairs, 0);
      },
    );

    test('a repair that could not run says so, rather than reporting an '
        'install that answers nothing', () async {
      final container = _container(
        _FakeCli(),
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

    test('with no grid tool there is nothing to install with, and it says so '
        'instead of failing quietly', () async {
      final container = _container(null);

      await container
          .read(agentInstallProvider.notifier)
          .install(AgentTool.hermes);

      final state = container.read(agentInstallProvider) as AgentInstallFailed;
      expect(state.message, contains("grid tool isn't installed"));
    });
  });

  group('the catalog', () {
    test('lists only agents the app can install, so no row on the screen is '
        'there to be looked at rather than used', () {
      expect(AgentTool.values, [AgentTool.hermes, AgentTool.codex]);
      expect(kChatAgent, AgentTool.hermes);
    });

    test('the id is what `grid agent install` takes', () {
      expect(AgentTool.hermes.id, 'hermes');
      expect(AgentTool.codex.id, 'codex');
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
