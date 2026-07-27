import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/codex/codex_tool.dart';
import 'package:grid_app/features/agent/hermes/hermes_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/node_setup/logic/background_agent_controller.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/infrastructure/cli/agent_installer.dart';

/// Records which install recipes it was handed — no download, no process.
class _FakeInstaller implements AgentInstaller {
  final specs = <AgentInstallSpec>[];

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    bool upgrade = false,
    void Function(String line)? onLog,
  }) async {
    specs.add(spec);
  }
}

/// Capabilities the top-up reads, with [installed] deciding what's missing —
/// overridden wholesale so the test never probes the real machine.
({ProviderContainer container, _FakeInstaller installer}) _make({
  Set<String> installed = const {},
}) {
  final installer = _FakeInstaller();
  final container = ProviderContainer(
    overrides: [
      agentInstallerProvider.overrideWithValue(installer),
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
  return (container: container, installer: installer);
}

void main() {
  test(
    'a computer missing an agent installs it without the installer screen',
    () async {
      // Hermes is present; Codex is the gap, so the top-up runs Codex's recipe
      // and nothing else. (OpenClaw is developer-only and never auto-installed.)
      final (:container, :installer) = _make(installed: {'hermes'});

      await container.read(backgroundAgentInstallerProvider).startIfNeeded();

      expect(installer.specs, hasLength(1));
      expect(installer.specs.single, isA<GithubReleaseBinary>());
      expect(
        (installer.specs.single as GithubReleaseBinary).executable,
        'codex',
      );
    },
  );

  test('a computer with every installable agent installs nothing', () async {
    final (:container, :installer) = _make(installed: {'hermes', 'codex'});

    await container.read(backgroundAgentInstallerProvider).startIfNeeded();

    expect(installer.specs, isEmpty);
  });

  test(
    'it runs at most once a session, however often the shell asks',
    () async {
      final (:container, :installer) = _make(installed: {'hermes'});
      final installerRunner = container.read(backgroundAgentInstallerProvider);

      await installerRunner.startIfNeeded();
      await installerRunner.startIfNeeded();

      expect(installer.specs, hasLength(1));
    },
  );
}
