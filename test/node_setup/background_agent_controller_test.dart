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
import 'package:grid_app/infrastructure/cli/claude_installer.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Claude Code's vendor installer, recorded rather than run — so the background
/// round never shells out to the real `curl | bash` on the test machine.
class _FakeClaudeInstaller implements ClaudeInstaller {
  final upgrades = <bool>[];

  @override
  Future<String?> install({required bool upgrade}) async {
    upgrades.add(upgrade);
    return null;
  }
}

/// Capabilities the installer reads, with [installed] deciding what's missing —
/// overridden wholesale so the test never probes the real machine.
ProviderContainer _container(
  FakeGridCliService? cli,
  ClaudeInstaller claude, {
  Set<AgentTool> installed = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      claudeInstallerProvider.overrideWithValue(claude),
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
  test('a computer missing agents tops up every one — the CLI ones and Claude '
      'Code together, without the installer screen', () async {
    // The full-screen installer only runs when there's no assistant at all, so
    // agents added to the catalog later (Claude Code among them) would never
    // arrive on a computer that was already set up.
    final cli = FakeGridCliService();
    final claude = _FakeClaudeInstaller();
    final container = _container(cli, claude, installed: {AgentTool.hermes});

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    // Codex through the CLI, Claude Code through its own installer — both in the
    // one background round.
    expect(cli.runCalls, [
      ['agent', 'install', AgentTool.codex.id],
    ]);
    expect(claude.upgrades, [false]);
  });

  test('a computer with every agent installs nothing', () async {
    final cli = FakeGridCliService();
    final claude = _FakeClaudeInstaller();
    final container = _container(
      cli,
      claude,
      installed: AgentTool.values.toSet(),
    );

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(cli.runCalls, isEmpty);
    expect(claude.upgrades, isEmpty);
  });

  test(
    'it runs at most once a session, however often the shell asks',
    () async {
      final cli = FakeGridCliService();
      final claude = _FakeClaudeInstaller();
      final container = _container(cli, claude, installed: {AgentTool.hermes});
      final installer = container.read(backgroundAgentInstallerProvider);

      await installer.startIfNeeded();
      await installer.startIfNeeded();

      expect(cli.runCalls, [
        ['agent', 'install', AgentTool.codex.id],
      ]);
      expect(claude.upgrades, [false]); // Claude Code fetched once, not twice.
    },
  );

  test('no grid tool still installs Claude Code — its installer needs nothing '
      'from the CLI — and does not crash on the ones that do', () async {
    final claude = _FakeClaudeInstaller();
    final container = _container(null, claude);

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    // Claude Code doesn't go through the grid CLI, so a missing CLI can't stop
    // it; Hermes and Codex simply fail (logged) and are skipped.
    expect(claude.upgrades, [false]);
  });
}
