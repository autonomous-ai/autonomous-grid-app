import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/agent_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/node_setup/logic/auto_host_controller.dart';
import 'package:grid_app/features/onboarding/logic/installer_rows.dart';
import 'package:grid_app/features/onboarding/logic/installer_stage.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

ProviderContainer _container({
  bool engine = false,
  bool model = false,
  bool agent = false,
  bool canHost = true,
}) {
  final container = ProviderContainer(
    overrides: [
      supportsBuiltInEngineProvider.overrideWithValue(canHost),
      engineStatusProvider.overrideWithValue(
        engine
            ? const EngineStatus(llamaInstalled: true, llamaPath: '/bin/llama')
            : EngineStatus.notInstalled,
      ),
      localModelsProvider.overrideWithValue(
        model
            ? const [LocalModel(name: 'm.gguf', path: '/m.gguf', sizeBytes: 1)]
            : const [],
      ),
      agentToolPathProvider(
        AgentTool.hermes,
      ).overrideWithValue(agent ? '/bin/hermes' : null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

InstallStatus _statusOf(ProviderContainer c, InstallerStage stage) => c
    .read(installerRowsProvider)
    .firstWhere((row) => row.stage == stage)
    .status;

void main() {
  group('installerNeeded — what a fresh machine is missing', () {
    test('a brand-new computer needs the installer', () {
      expect(_container().read(installerNeededProvider), isTrue);
    });

    test('missing only the assistant still needs it', () {
      final c = _container(engine: true, model: true);
      expect(c.read(installerNeededProvider), isTrue);
    });

    test('a fully set-up computer does not', () {
      final c = _container(engine: true, model: true, agent: true);
      expect(c.read(installerNeededProvider), isFalse);
    });

    test('a machine that cannot host never sees it', () {
      final c = _container(canHost: false);
      expect(c.read(installerNeededProvider), isFalse);
    });
  });

  group('rows read the machine, not a flag', () {
    test('what is already installed shows as done, and is not redone', () {
      final c = _container(engine: true, agent: true);

      expect(_statusOf(c, InstallerStage.engine), InstallStatus.done);
      expect(_statusOf(c, InstallerStage.agent), InstallStatus.done);
      // Nothing has downloaded the model yet.
      expect(_statusOf(c, InstallerStage.model), InstallStatus.pending);
    });

    test('a fresh machine has every install step pending', () {
      final c = _container();

      expect(_statusOf(c, InstallerStage.engine), InstallStatus.pending);
      expect(_statusOf(c, InstallerStage.model), InstallStatus.pending);
      expect(_statusOf(c, InstallerStage.agent), InstallStatus.pending);
    });

    test('the checklist is the five stages, in order', () {
      final rows = _container().read(installerRowsProvider);

      expect(rows.map((r) => r.stage), InstallerStage.values);
    });
  });
}
