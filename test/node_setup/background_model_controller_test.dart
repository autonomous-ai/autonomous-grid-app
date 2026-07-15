import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/node_setup/logic/auto_host_controller.dart';
import 'package:grid_app/features/node_setup/logic/background_model_controller.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/model_catalog.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

const _model = CatalogModel(
  label: 'qwen',
  repoFile: 'unsloth/Repo/file.gguf',
  kind: 'language',
);

const _localModel = LocalModel(name: 'm.gguf', path: '/m.gguf', sizeBytes: 1);

NodeCapabilities _caps({int models = 0}) => NodeCapabilities(
  textBackends: const [],
  engine: const EngineStatus(llamaInstalled: true),
  media: MediaStatus.notInstalled,
  localModelCount: models,
  recommendedModel: _model,
);

/// Records whether sharing was attempted, without touching the real grid or
/// `~/.grid` — the real controller reads the selected network off disk.
class _FakeAutoHost extends AutoHostController {
  bool shared = false;

  @override
  Future<void> startIfReady() async {
    shared = true;
  }
}

ProviderContainer _container({
  required FakeGridCliService cli,
  bool canHost = true,
  bool engineInstalled = true,
  bool localChosen = true,
  List<LocalModel> models = const [],
  _FakeAutoHost? autoHost,
}) {
  final container = ProviderContainer(
    overrides: [
      supportsBuiltInEngineProvider.overrideWithValue(canHost),
      // The download is now gated on the user having chosen "run local"; the
      // real value comes off the persisted onboarding decision (off disk), so
      // tests set it explicitly to stay deterministic.
      localModelChosenProvider.overrideWithValue(localChosen),
      engineStatusProvider.overrideWithValue(
        engineInstalled
            ? const EngineStatus(llamaInstalled: true, llamaPath: '/bin/llama')
            : EngineStatus.notInstalled,
      ),
      localModelsProvider.overrideWithValue(models),
      gridCliServiceProvider.overrideWithValue(cli),
      nodeCapabilitiesProvider.overrideWith((ref) async => _caps()),
      if (autoHost != null)
        autoHostControllerProvider.overrideWith(() => autoHost),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('downloads the recommended model, then shares it, when the engine is '
      'ready and no model is on disk', () async {
    final cli = FakeGridCliService()
      ..stubPull(
        const ['pull', 'qwen'],
        const [
          DownloadProgress(doneMb: 100, totalMb: 200, pct: 50),
          DownloadProgress(doneMb: 200, totalMb: 200, pct: 100),
        ],
      );
    final autoHost = _FakeAutoHost();
    final container = _container(cli: cli, autoHost: autoHost);

    await container
        .read(backgroundModelControllerProvider.notifier)
        .startIfNeeded();

    expect(
      container.read(backgroundModelControllerProvider),
      isA<ModelDownloadDone>(),
    );
    expect(autoHost.shared, isTrue);
  });

  test(
    'does nothing — no download — when a model is already on disk',
    () async {
      final container = _container(
        cli: FakeGridCliService(),
        models: const [_localModel],
      );

      await container
          .read(backgroundModelControllerProvider.notifier)
          .startIfNeeded();

      expect(
        container.read(backgroundModelControllerProvider),
        isA<ModelDownloadIdle>(),
      );
    },
  );

  test(
    'does nothing when the user did not choose to run a model locally — a '
    'cloud-provider or invite user is never handed a several-GB download',
    () async {
      final container = _container(
        cli: FakeGridCliService(),
        localChosen: false,
      );

      await container
          .read(backgroundModelControllerProvider.notifier)
          .startIfNeeded();

      expect(
        container.read(backgroundModelControllerProvider),
        isA<ModelDownloadIdle>(),
      );
    },
  );

  test('leaves a machine that cannot host alone', () async {
    final container = _container(cli: FakeGridCliService(), canHost: false);

    await container
        .read(backgroundModelControllerProvider.notifier)
        .startIfNeeded();

    expect(
      container.read(backgroundModelControllerProvider),
      isA<ModelDownloadIdle>(),
    );
  });

  test('waits for the engine — nothing to run a model on yet', () async {
    final container = _container(
      cli: FakeGridCliService(),
      engineInstalled: false,
    );

    await container
        .read(backgroundModelControllerProvider.notifier)
        .startIfNeeded();

    expect(
      container.read(backgroundModelControllerProvider),
      isA<ModelDownloadIdle>(),
    );
  });
}
