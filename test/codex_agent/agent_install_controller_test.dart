import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/agent_install_controller.dart';
import 'package:grid_app/features/codex_agent/logic/agent_tool.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/host_shell_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';

class _FakeShell implements HostShellService {
  _FakeShell({this.opens = true});
  bool opens;
  final commands = <String>[];

  @override
  Future<bool> openTerminal(String command) async {
    commands.add(command);
    return opens;
  }
}

/// A [GridCliService] whose install process the test drives: it records the argv
/// and completes with [exit] when the test says so.
class _ScriptedCli implements GridCliService {
  final args = <List<String>>[];
  final lines = StreamController<CliLine>.broadcast();
  final exit = Completer<int>();
  var killed = false;

  @override
  Future<GridProcess> start(
    List<String> argv, {
    Map<String, String>? environment,
  }) async {
    args.add(argv);
    return GridProcess(
      lines: lines.stream,
      exitCode: exit.future,
      kill: () => killed = true,
    );
  }

  @override
  Future<CliResult> run(List<String> argv) async =>
      throw UnimplementedError('the install streams; it never uses run()');

  @override
  Stream<DownloadProgress> pull(List<String> argv) =>
      throw UnimplementedError('the install streams; it never uses pull()');
}

/// A mutable tool path so a test can flip "installed" mid-flow.
class _Path {
  String? value;
}

({ProviderContainer container, _FakeShell shell, _ScriptedCli cli, _Path path})
_harness(AgentTool tool, {bool shellOpens = true}) {
  final shell = _FakeShell(opens: shellOpens);
  final cli = _ScriptedCli();
  final path = _Path();
  final container = ProviderContainer(
    overrides: [
      hostShellServiceProvider.overrideWithValue(shell),
      gridCliServiceProvider.overrideWithValue(cli),
      agentToolPathProvider(tool).overrideWith((ref) => path.value),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, shell: shell, cli: cli, path: path);
}

void main() {
  group('hermes — installed by the app, no Homebrew, no Terminal', () {
    test('runs `grid agent install hermes` and never opens Terminal', () async {
      final h = _harness(AgentTool.hermes);
      final controller = h.container.read(
        agentInstallControllerProvider.notifier,
      );

      final running = controller.start(AgentTool.hermes);
      await pumpEventQueue();

      expect(h.cli.args.single, ['agent', 'install', 'hermes']);
      expect(h.shell.commands, isEmpty);
      expect(
        h.container.read(agentInstallControllerProvider),
        isA<AgentSetupRunning>(),
      );

      // The install lands the binary, then the process exits.
      h.path.value = '/Users/me/.grid/bin/hermes';
      h.cli.exit.complete(0);
      await running;

      expect(
        h.container.read(agentInstallControllerProvider),
        isA<AgentSetupDone>(),
      );
    });

    test('fails with actionable copy when the tool never appears', () async {
      final h = _harness(AgentTool.hermes);
      final controller = h.container.read(
        agentInstallControllerProvider.notifier,
      );

      final running = controller.start(AgentTool.hermes);
      await pumpEventQueue();
      // Exit 0 but nothing installed — treat as a failure, not a false success.
      h.cli.exit.complete(0);
      await running;

      final state = h.container.read(agentInstallControllerProvider);
      expect(state, isA<AgentSetupFailed>());
      expect((state as AgentSetupFailed).message, contains('try again'));
    });

    test('fails when the grid CLI is unavailable', () async {
      final container = ProviderContainer(
        overrides: [gridCliServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);

      await container
          .read(agentInstallControllerProvider.notifier)
          .start(AgentTool.hermes);

      expect(
        container.read(agentInstallControllerProvider),
        isA<AgentSetupFailed>(),
      );
    });
  });

  group('codex — still handed to Terminal (debug-only backend)', () {
    test('opens the cask install command', () async {
      final h = _harness(AgentTool.codex);
      await h.container
          .read(agentInstallControllerProvider.notifier)
          .start(AgentTool.codex);

      expect(
        h.container.read(agentInstallControllerProvider),
        isA<AgentSetupAwaitingTerminal>(),
      );
      expect(h.shell.commands.single, 'brew install --cask codex');
    });

    test('fails when Terminal cannot be opened', () async {
      final h = _harness(AgentTool.codex, shellOpens: false);
      await h.container
          .read(agentInstallControllerProvider.notifier)
          .start(AgentTool.codex);

      expect(
        h.container.read(agentInstallControllerProvider),
        isA<AgentSetupFailed>(),
      );
    });

    test('Continue reaches Done once the tool is detected', () async {
      final h = _harness(AgentTool.codex);
      final controller = h.container.read(
        agentInstallControllerProvider.notifier,
      );

      await controller.start(AgentTool.codex);
      h.path.value = '/opt/homebrew/bin/codex';
      controller.continueSetup();

      expect(
        h.container.read(agentInstallControllerProvider),
        isA<AgentSetupDone>(),
      );
    });

    test('Continue re-prompts while the tool is still missing', () async {
      final h = _harness(AgentTool.codex);
      final controller = h.container.read(
        agentInstallControllerProvider.notifier,
      );

      await controller.start(AgentTool.codex);
      controller.continueSetup();

      final state = h.container.read(agentInstallControllerProvider);
      expect(state, isA<AgentSetupAwaitingTerminal>());
      expect((state as AgentSetupAwaitingTerminal).note, isNotNull);
    });
  });
}
