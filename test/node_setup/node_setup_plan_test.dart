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
  bool agent = false,
  CatalogModel? recommended = _model,
}) =>
    NodeCapabilities(
      textBackends: backends,
      engine: engineInstalled
          ? const EngineStatus(llamaInstalled: true)
          : EngineStatus.notInstalled,
      media: media,
      localModelCount: models,
      hasAgent: agent,
      recommendedModel: recommended,
    );

DetectedBackend _ollama(
        {List<String> models = const ['gemma'], bool running = true}) =>
    DetectedBackend(
      kind: BackendKind.ollama,
      label: 'Ollama',
      baseUrl: 'http://localhost:11434/v1',
      models: models,
      running: running,
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
  test('media is off by default — a fresh machine sets up text only', () {
    final plan = buildSetupPlan(_caps());
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
    ]);
  });

  test('a machine that already has the assistant does not reinstall it', () {
    final plan = buildSetupPlan(_caps(agent: true));
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('the assistant is installed without a package manager', () {
    final plan = buildSetupPlan(_caps());
    final step = plan.firstWhere((s) => s.action == SetupAction.installAgent);
    expect(step.args, ['agent', 'install', 'hermes']);
  });

  test('with media enabled, a fresh machine installs both engines', () {
    final plan = buildSetupPlan(_caps(), includeMedia: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('a running Ollama does not excuse Grid from setting itself up', () {
    // Regression: Grid used to treat someone else's server as "text inference
    // covered" and install nothing — leaving a grid with no model on it. Grid
    // sets up its own engine and model; the user's Ollama is theirs to share
    // deliberately, from the Engines tab.
    final plan = buildSetupPlan(_caps(backends: [_ollama()]));
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
    ]);
  });

  test('a stopped Ollama changes nothing either', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama(running: false)]));
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
    ]);
  });

  test('with media enabled, a machine with Ollama still installs everything', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama()]), includeMedia: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('falls back to a default model when the catalog recommends none', () {
    final plan = buildSetupPlan(_caps(recommended: null), isMacOS: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installAgent,
    ]);
    final pull = plan.firstWhere((s) => s.action == SetupAction.pullModel);
    expect(pull.args, [
      'pull',
      'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
    ]);
  });

  test('a fully set-up node needs no steps', () {
    final plan = buildSetupPlan(
      _caps(
        engineInstalled: true,
        media: _completeMedia,
        models: 1,
        agent: true,
      ),
      includeMedia: true,
    );
    expect(plan, isEmpty);
  });

  test('the model step pulls the catalog label, not a hardcoded id', () {
    final plan = buildSetupPlan(_caps());
    final pull = plan.firstWhere((s) => s.action == SetupAction.pullModel);
    expect(pull.args, ['pull', 'qwen36-35b-a3b-mtp']);
  });

  test('the first-run installer plan leaves the model out — it downloads in '
      'the background so the user gets in sooner', () {
    final plan = buildSetupPlan(_caps(), includeModel: false);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.installAgent,
    ]);
  });

  test('modelPullStep is null once a model is on disk, present otherwise', () {
    expect(modelPullStep(_caps(models: 1)), isNull);
    final step = modelPullStep(_caps());
    expect(step?.action, SetupAction.pullModel);
    expect(step?.args, ['pull', 'qwen36-35b-a3b-mtp']);
  });
}
