import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agent/logic/claude_tool.dart';
import 'package:grid_app/features/agent/logic/codex_tool.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/node_setup/logic/background_agent_controller.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Capabilities the installer reads, with [installed] deciding what's missing —
/// overridden wholesale so the test never probes the real machine.
ProviderContainer _container(
  FakeGridCliService? cli, {
  Set<AgentTool> installed = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      nodeCapabilitiesProvider.overrideWith(
        (_) async => NodeCapabilities(
          textBackends: const [],
          engine: EngineStatus.notInstalled,
          media: MediaStatus.notInstalled,
          localModelCount: 0,
          installedAgents: installed,
        ),
      ),
      // The re-probe at the end must not walk the real PATH.
      hermesPathProvider.overrideWith((_) => null),
      codexPathProvider.overrideWith((_) => null),
      claudePathProvider.overrideWith((_) => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'a computer missing an agent gets it without the installer screen',
    () async {
      // The full-screen installer only runs on a machine that has no assistant
      // at all, so an agent added to the catalog later would never arrive on a
      // computer that was already set up.
      final cli = FakeGridCliService();
      final container = _container(cli, installed: {AgentTool.hermes});

      await container.read(backgroundAgentInstallerProvider).startIfNeeded();

      // Only the CLI-packaged agents are topped up silently. Claude Code isn't
      // one of them — the CLI can't fetch it, and a whole vendor CLI is the
      // user's call on the Agents tab — so it is never in a background round.
      expect(cli.runCalls, [
        for (final tool in AgentTool.values)
          if (tool != AgentTool.hermes && tool.packagedByCli)
            ['agent', 'install', tool.id],
      ]);
      expect(
        cli.runCalls,
        isNot(contains(['agent', 'install', AgentTool.claude.id])),
      );
    },
  );

  test('a computer with every CLI-packaged agent installs nothing', () async {
    final cli = FakeGridCliService();
    final installed = AgentTool.values.where((t) => t.packagedByCli).toSet();
    final container = _container(cli, installed: installed);

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(cli.runCalls, isEmpty);
  });

  test(
    'it runs at most once a session, however often the shell asks',
    () async {
      final cli = FakeGridCliService();
      final container = _container(cli, installed: {AgentTool.hermes});
      final installer = container.read(backgroundAgentInstallerProvider);

      await installer.startIfNeeded();
      await installer.startIfNeeded();

      final cliPackaged = AgentTool.values.where((t) => t.packagedByCli).length;
      expect(cli.runCalls, hasLength(cliPackaged - 1));
    },
  );

  test('no grid tool means nothing to install with, and no crash', () async {
    final container = _container(null);

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();
  });
}
