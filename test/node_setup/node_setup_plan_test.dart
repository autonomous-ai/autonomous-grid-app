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
  bool hasHomebrew = true,
  CatalogModel? recommended = _model,
}) =>
    NodeCapabilities(
      textBackends: backends,
      engine: engineInstalled
          ? const EngineStatus(llamaInstalled: true)
          : EngineStatus.notInstalled,
      media: media,
      localModelCount: models,
      hasHomebrew: hasHomebrew,
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
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('on macOS without Homebrew, setup installs it before the engine', () {
    final plan = buildSetupPlan(_caps(hasHomebrew: false), isMacOS: true);
    expect(_actions(plan), [
      SetupAction.installHomebrew,
      SetupAction.installLlama,
      SetupAction.pullModel,
    ]);
    // The Homebrew step runs via the installer, not the CLI — no grid args.
    expect(plan.first.args, isEmpty);
  });

  test('the Homebrew step is macOS-only', () {
    final plan = buildSetupPlan(_caps(hasHomebrew: false), isMacOS: false);
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('no Homebrew step when the built-in engine is not being installed', () {
    // Text inference already covered by a running Ollama → no llama, so no brew.
    final plan = buildSetupPlan(
      _caps(backends: [_ollama()], hasHomebrew: false),
      isMacOS: true,
    );
    expect(plan, isEmpty);
  });

  test('with media enabled, a fresh machine installs both engines', () {
    final plan = buildSetupPlan(_caps(), includeMedia: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('an existing Ollama with models needs nothing (media off)', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama()]));
    expect(plan, isEmpty);
  });

  test('an installed-but-not-running Ollama still needs the built-in engine', () {
    // A detected-but-stopped backend can't serve, so node setup must still
    // install llama.cpp and pull a model rather than assume text is covered.
    final plan = buildSetupPlan(_caps(backends: [_ollama(running: false)]));
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('with media enabled, an existing Ollama still installs ComfyUI', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama()]), includeMedia: true);
    expect(_actions(plan), [
      SetupAction.installComfy,
      SetupAction.pullMediaBundle,
    ]);
  });

  test('falls back to a default model when the catalog recommends none', () {
    final plan = buildSetupPlan(_caps(recommended: null), isMacOS: true);
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
    final pull = plan.firstWhere((s) => s.action == SetupAction.pullModel);
    expect(pull.args, [
      'pull',
      'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
    ]);
  });

  test('a fully set-up node needs no steps', () {
    final plan = buildSetupPlan(
      _caps(engineInstalled: true, media: _completeMedia, models: 1),
      includeMedia: true,
    );
    expect(plan, isEmpty);
  });

  test('the model step pulls the catalog label, not a hardcoded id', () {
    final plan = buildSetupPlan(_caps());
    final pull = plan.firstWhere((s) => s.action == SetupAction.pullModel);
    expect(pull.args, ['pull', 'qwen36-35b-a3b-mtp']);
  });
}
