import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/node_setup/logic/background_agent_controller.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/infrastructure/cli/agent_spec_installer.dart';
import 'package:grid_app/infrastructure/cli/claude_installer.dart';

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

/// The recipe runner, recorded rather than run — nothing is downloaded on the
/// test machine.
class _FakeSpecInstaller implements AgentSpecInstaller {
  _FakeSpecInstaller({this.failure});

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

/// Capabilities the installer reads, with [installed] deciding what's missing —
/// overridden wholesale so the test never probes the real machine.
ProviderContainer _container(
  AgentSpecInstaller specs,
  ClaudeInstaller claude, {
  Set<AgentTool> installed = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      agentSpecInstallerProvider.overrideWithValue(specs),
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
  test('a computer missing agents tops up every one — the app-fetched ones and '
      'Claude Code together, without the installer screen', () async {
    // The full-screen installer only runs when there's no assistant at all, so
    // agents added to the catalog later (Claude Code among them) would never
    // arrive on a computer that was already set up.
    final specs = _FakeSpecInstaller();
    final claude = _FakeClaudeInstaller();
    final container = _container(specs, claude, installed: {AgentTool.hermes});

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    // Codex through its release binary, Claude Code through its vendor
    // installer — both in the one background round.
    expect(specs.ran.any((s) => s is GithubReleaseBinary), isTrue); // Codex
    expect(claude.upgrades, [false]);
  });

  test('a computer with every agent installs nothing', () async {
    final specs = _FakeSpecInstaller();
    final claude = _FakeClaudeInstaller();
    final container = _container(
      specs,
      claude,
      installed: AgentTool.values.toSet(),
    );

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(specs.ran, isEmpty);
    expect(claude.upgrades, isEmpty);
  });

  test(
    'it runs at most once a session, however often the shell asks',
    () async {
      final specs = _FakeSpecInstaller();
      final claude = _FakeClaudeInstaller();
      final container = _container(
        specs,
        claude,
        installed: {AgentTool.hermes},
      );
      final installer = container.read(backgroundAgentInstallerProvider);

      await installer.startIfNeeded();
      await installer.startIfNeeded();

      // Codex once — not twice across two asks.
      expect(specs.ran, hasLength(1));
      expect(claude.upgrades, [false]); // Claude Code fetched once, not twice.
    },
  );

  test('one agent that will not download does not take the others with it — '
      'the round logs it and carries on', () async {
    final claude = _FakeClaudeInstaller();
    final container = _container(
      _FakeSpecInstaller(
        failure: const AgentInstallException('could not reach github.com'),
      ),
      claude,
    );

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(claude.upgrades, [false]);
  });
}
