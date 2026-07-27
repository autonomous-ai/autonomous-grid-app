import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/agent_registry.dart';
import 'package:grid_app/features/agent/codex/codex_tool.dart';
import 'package:grid_app/features/agent/hermes/hermes_tool.dart';
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
  Set<String> installed = const {},
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
          installedAgentIds: installed,
        ),
      ),
      // The re-probe at the end must not walk the real PATH.
      hermesPathProvider.overrideWith((_) => null),
      codexPathProvider.overrideWith((_) => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The agents background setup can fetch — the grid-managed ones. OpenClaw
/// installs from its own site, so it never appears in an install run.
final _installable = installableAgents;

void main() {
  test(
    'a computer missing an agent gets it without the installer screen',
    () async {
      // The full-screen installer only runs on a machine that has no assistant
      // at all, so an agent added to the catalog later would never arrive on a
      // computer that was already set up.
      final cli = FakeGridCliService();
      final container = _container(cli, installed: {'hermes'});

      await container.read(backgroundAgentInstallerProvider).startIfNeeded();

      expect(cli.runCalls, [
        for (final agent in _installable)
          if (agent.id != 'hermes') ['agent', 'install', agent.id],
      ]);
    },
  );

  test('a computer with every agent installs nothing', () async {
    final cli = FakeGridCliService();
    final container = _container(
      cli,
      installed: _installable.map((a) => a.id).toSet(),
    );

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(cli.runCalls, isEmpty);
  });

  test(
    'it runs at most once a session, however often the shell asks',
    () async {
      final cli = FakeGridCliService();
      final container = _container(cli, installed: {'hermes'});
      final installer = container.read(backgroundAgentInstallerProvider);

      await installer.startIfNeeded();
      await installer.startIfNeeded();

      expect(cli.runCalls, hasLength(_installable.length - 1));
    },
  );

  test('no grid tool means nothing to install with, and no crash', () async {
    final container = _container(null);

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();
  });
}
