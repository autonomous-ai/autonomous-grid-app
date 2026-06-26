import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/model_catalog.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/features/node_setup/logic/node_setup_plan.dart';
import 'package:grid_app/features/provider_node/logic/backend_detector.dart';

const _model = CatalogModel(
  label: 'qwen36-35b-a3b-mtp',
  repoFile: 'unsloth/Repo/file.gguf',
  kind: 'language',
);

NodeCapabilities _caps({
  List<DetectedBackend> backends = const [],
  bool engineInstalled = false,
  MediaStatus media = MediaStatus.notInstalled,
  int models = 0,
  CatalogModel? recommended = _model,
}) =>
    NodeCapabilities(
      textBackends: backends,
      engine: engineInstalled
          ? const EngineStatus(llamaInstalled: true)
          : EngineStatus.notInstalled,
      media: media,
      localModelCount: models,
      recommendedModel: recommended,
    );

DetectedBackend _ollama({List<String> models = const ['gemma']}) =>
    DetectedBackend(
      kind: BackendKind.ollama,
      label: 'Ollama',
      baseUrl: 'http://localhost:11434/v1',
      models: models,
    );

const _completeMedia = MediaStatus(
  installed: true,
  running: false,
  bundles: [
    MediaBundleStatus(name: defaultMediaBundle, filesPresent: 3, filesTotal: 3),
  ],
);

List<SetupAction> _actions(List<SetupStep> steps) =>
    steps.map((s) => s.action).toList();

void main() {
  test('a fresh machine installs both engines and downloads both', () {
    final plan = buildSetupPlan(_caps());
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('skips the model step when the catalog recommends none', () {
    final plan = buildSetupPlan(_caps(recommended: null));
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('an existing Ollama with models skips the text engine and model', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama()]));
    expect(_actions(plan), [
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('a fully set-up node needs no steps', () {
    final plan = buildSetupPlan(
      _caps(engineInstalled: true, media: _completeMedia, models: 1),
    );
    expect(plan, isEmpty);
  });

  test('includeMedia: false skips all ComfyUI work', () {
    final plan = buildSetupPlan(_caps(), includeMedia: false);
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('the model step pulls the catalog label, not a hardcoded id', () {
    final plan = buildSetupPlan(_caps());
    final pull = plan.firstWhere((s) => s.action == SetupAction.pullModel);
    expect(pull.args, ['models', 'pull', 'qwen36-35b-a3b-mtp']);
  });
}
