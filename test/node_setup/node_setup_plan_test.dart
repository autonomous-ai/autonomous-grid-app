import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
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
  Set<AgentTool> agents = const {},
  CatalogModel? recommended = _model,
}) => NodeCapabilities(
  textBackends: backends,
  engine: engineInstalled
      ? const EngineStatus(llamaInstalled: true)
      : EngineStatus.notInstalled,
  media: media,
  localModelCount: models,
  installedAgents: agents,
  recommendedModel: recommended,
);

/// Every agent the catalog knows — a machine with nothing left to install.
final _allAgents = AgentTool.values.toSet();

/// The agents an unattended plan can fetch — the CLI-packaged ones. Claude Code
/// is installed only on request (see [AgentTool.packagedByCli]), so it never
/// appears in a setup plan.
final _cliAgents = AgentTool.values.where((t) => t.packagedByCli).toList();

/// What a bare machine owes the agents: one install step per CLI-packaged agent.
/// Written as a function of the catalog so adding an agent doesn't need every
/// expectation in this file rewritten.
final _agentSteps = List.filled(_cliAgents.length, SetupAction.installAgent);

DetectedBackend _ollama({
  List<String> models = const ['gemma'],
  bool running = true,
}) => DetectedBackend(
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
      ..._agentSteps,
    ]);
  });

  test('a machine that already has the assistant does not reinstall it', () {
    final plan = buildSetupPlan(_caps(agents: _allAgents));
    expect(_actions(plan), [SetupAction.installLlama, SetupAction.pullModel]);
  });

  test('the assistant is installed without a package manager', () {
    final plan = buildSetupPlan(_caps());
    final step = plan.firstWhere((s) => s.action == SetupAction.installAgent);
    expect(step.args, ['agent', 'install', 'hermes']);
  });

  test('a first run fetches every CLI-packaged agent, not just the one that '
      'answers — and never Claude Code, which the CLI cannot install', () {
    // An agent nobody installed is a row the user can only look at, so setup
    // brings in every one the CLI can fetch — and the one chat defaults to goes
    // first. Claude Code is left out: a whole vendor CLI is the user's call.
    final steps = agentInstallSteps(_caps());
    expect(
      steps.map((s) => s.args),
      _cliAgents.map((t) => ['agent', 'install', t.id]),
    );
    expect(steps.first.args.last, kChatAgent.id);
    expect(steps.every((s) => s.args.last != AgentTool.claude.id), isTrue);
  });

  test('only the default agent is worth stopping a first run for', () {
    // A second assistant that won't download must not leave a new user staring
    // at a red screen when the one that answers chat is already in.
    final steps = agentInstallSteps(_caps());
    final required = steps.where((s) => !s.optional).toList();
    expect(required, hasLength(1));
    expect(required.single.args.last, kChatAgent.id);
  });

  test('having the default agent still gets you the other CLI-packaged one', () {
    final steps = agentInstallSteps(_caps(agents: {kChatAgent}));
    expect(steps, hasLength(_cliAgents.length - 1));
    expect(steps.every((s) => s.args.last != kChatAgent.id), isTrue);
  });

  test('with media enabled, a fresh machine installs both engines', () {
    final plan = buildSetupPlan(_caps(), includeMedia: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      ..._agentSteps,
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
      ..._agentSteps,
    ]);
  });

  test('a stopped Ollama changes nothing either', () {
    final plan = buildSetupPlan(_caps(backends: [_ollama(running: false)]));
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      ..._agentSteps,
    ]);
  });

  test(
    'with media enabled, a machine with Ollama still installs everything',
    () {
      final plan = buildSetupPlan(
        _caps(backends: [_ollama()]),
        includeMedia: true,
      );
      expect(_actions(plan), [
        SetupAction.installLlama,
        SetupAction.pullModel,
        ..._agentSteps,
        SetupAction.installComfy,
        SetupAction.pullMediaBundle,
      ]);
    },
  );

  test('falls back to a default model when the catalog recommends none', () {
    final plan = buildSetupPlan(_caps(recommended: null), isMacOS: true);
    expect(_actions(plan), [
      SetupAction.installLlama,
      SetupAction.pullModel,
      ..._agentSteps,
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
        agents: _allAgents,
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

  test('leaving the model out still installs the engine and assistant', () {
    final plan = buildSetupPlan(_caps(), includeModel: false);
    expect(_actions(plan), [SetupAction.installLlama, ..._agentSteps]);
  });

  test('the first-run installer plan is the assistant only — no engine, no '
      'model — so running a model locally stays a deliberate choice', () {
    final plan = buildSetupPlan(
      _caps(),
      includeEngine: false,
      includeModel: false,
    );
    expect(_actions(plan), _agentSteps);
  });

  test(
    'the "run local" choice installs the engine but still not the model — it '
    'downloads in the background after the choice',
    () {
      final plan = buildSetupPlan(
        _caps(agents: _allAgents),
        includeModel: false,
      );
      expect(_actions(plan), [SetupAction.installLlama]);
    },
  );

  test('modelPullStep is null once a model is on disk, present otherwise', () {
    expect(modelPullStep(_caps(models: 1)), isNull);
    final step = modelPullStep(_caps());
    expect(step?.action, SetupAction.pullModel);
    expect(step?.args, ['pull', 'qwen36-35b-a3b-mtp']);
  });
}
