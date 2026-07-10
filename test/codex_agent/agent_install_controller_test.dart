import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/agent_install_controller.dart';
import 'package:grid_app/features/codex_agent/logic/agent_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/infrastructure/cli/host_shell_service.dart';

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

/// A mutable tool path so a test can flip "installed" mid-flow.
class _Path {
  String? value;
}

({ProviderContainer container, _FakeShell shell, _Path path}) _harness(
  AgentTool tool, {
  required bool brew,
  bool shellOpens = true,
}) {
  final shell = _FakeShell(opens: shellOpens);
  final path = _Path();
  final container = ProviderContainer(
    overrides: [
      homebrewInstalledProvider.overrideWithValue(brew),
      hostShellServiceProvider.overrideWithValue(shell),
      agentToolPathProvider(tool).overrideWith((ref) => path.value),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, shell: shell, path: path);
}

void main() {
  test('start without Homebrew fails with guidance', () async {
    final h = _harness(AgentTool.codex, brew: false);
    await h.container
        .read(agentInstallControllerProvider.notifier)
        .start(AgentTool.codex);

    final state = h.container.read(agentInstallControllerProvider);
    expect(state, isA<AgentSetupFailed>());
    expect((state as AgentSetupFailed).message, contains('Homebrew'));
  });

  test('codex opens the cask install command', () async {
    final h = _harness(AgentTool.codex, brew: true);
    await h.container
        .read(agentInstallControllerProvider.notifier)
        .start(AgentTool.codex);

    expect(
      h.container.read(agentInstallControllerProvider),
      isA<AgentSetupInstalling>(),
    );
    expect(h.shell.commands.single, 'brew install --cask codex');
  });

  test('hermes opens the formula install command', () async {
    final h = _harness(AgentTool.hermes, brew: true);
    await h.container
        .read(agentInstallControllerProvider.notifier)
        .start(AgentTool.hermes);

    expect(h.shell.commands.single, 'brew install hermes-agent');
  });

  test('start fails when Terminal cannot be opened', () async {
    final h = _harness(AgentTool.codex, brew: true, shellOpens: false);
    await h.container
        .read(agentInstallControllerProvider.notifier)
        .start(AgentTool.codex);

    expect(
      h.container.read(agentInstallControllerProvider),
      isA<AgentSetupFailed>(),
    );
  });

  test('Continue reaches Done once the tool is detected', () async {
    final h = _harness(AgentTool.hermes, brew: true);
    final controller = h.container.read(
      agentInstallControllerProvider.notifier,
    );

    await controller.start(AgentTool.hermes);
    h.path.value = '/opt/homebrew/bin/hermes';
    controller.continueSetup();

    expect(
      h.container.read(agentInstallControllerProvider),
      isA<AgentSetupDone>(),
    );
  });

  test('Continue re-prompts while the tool is still missing', () async {
    final h = _harness(AgentTool.codex, brew: true);
    final controller = h.container.read(
      agentInstallControllerProvider.notifier,
    );

    await controller.start(AgentTool.codex);
    controller.continueSetup();

    final state = h.container.read(agentInstallControllerProvider);
    expect(state, isA<AgentSetupInstalling>());
    expect((state as AgentSetupInstalling).note, isNotNull);
  });
}
