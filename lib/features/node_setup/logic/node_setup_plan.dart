import 'dart:io';

import '../../agents/logic/agent_catalog.dart';
import 'node_capabilities.dart';
import 'node_setup_config.dart';

/// One install/download action in the node-setup sequence.
enum SetupAction {
  installLlama,
  pullModel,
  installAgent,
  installComfy,
  pullMediaBundle,
}

/// A single planned step: what to run, why, and how to run it. [args] is the
/// exact `grid` argument vector; [isDownload] routes long downloads through the
/// progress-streaming `pull` path instead of plain `start`.
class SetupStep {
  const SetupStep({
    required this.action,
    required this.title,
    required this.detail,
    required this.args,
    required this.isDownload,
    this.agent,
  });

  final SetupAction action;
  final String title;
  final String detail;
  final List<String> args;
  final bool isDownload;

  /// The agent this step installs, for a [SetupAction.installAgent] step. The
  /// app runs the agent's own recipe rather than a `grid` subcommand, so such a
  /// step carries an agent instead of an argv and [args] is empty.
  final AgentTool? agent;
}

/// Default ComfyUI bundle so the media engine is usable right after install.
const defaultMediaBundle = 'image_generation';

/// Fallback model used only when `grid catalog` is unavailable (CLI error, empty
/// target list, parse miss) — so a node never finishes with an engine but no
/// model. These are the catalog's own picks expressed as `repo:file`, which
/// `grid pull` parses directly without a catalog lookup, making them robust when
/// the catalog itself can't be read.
String _fallbackModelSpec({bool? isMacOS}) => (isMacOS ?? Platform.isMacOS)
    ? 'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf'
    : 'unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q5_K_XL.gguf';

/// Decides the sequence of steps that makes this computer a usable node,
/// installing only what's actually missing. Pure and side-effect free, so it's
/// trivially testable. Steps run in list order; the ComfyUI bundle download is
/// sequenced after its install. The model to pull prefers
/// [NodeCapabilities.recommendedModel] (the CLI catalog) and falls back to
/// [_fallbackModelSpec] so the model download is never silently skipped.
///
/// "Missing" is judged against **Grid's own** engine and models, not against
/// whatever else the machine happens to run. A developer with Ollama already up
/// used to get an empty plan — Grid would install nothing, own nothing, and the
/// grid would sit there with no model on it. Grid sets up its own engine and its
/// own model so it can serve them reliably; another server the user runs is
/// something they can *also* share, from the Engines tab, on purpose.
List<SetupStep> buildSetupPlan(
  NodeCapabilities caps, {
  bool includeMedia = kMediaSetupEnabled,
  bool includeModel = true,
  bool includeEngine = true,
  bool? isMacOS,
}) {
  final steps = <SetupStep>[];

  // The first-run installer sets [includeEngine] false: the built-in engine is
  // now a deliberate choice ("run a model on this computer"), not something every
  // Mac installs up front — so it's installed only when the user picks that path.
  if (includeEngine && !caps.engine.llamaInstalled) {
    steps.add(
      const SetupStep(
        action: SetupAction.installLlama,
        title: 'Install the built-in engine',
        detail: 'The software that runs AI models on this computer.',
        args: ['engine', 'install', 'llama.cpp'],
        isDownload: false,
      ),
    );
  }

  // The first-run installer sets [includeModel] false and downloads the model in
  // the background instead (see BackgroundModelController), so the user reaches
  // chat without waiting several GB. The manual Engines-tab setup keeps it.
  if (includeModel) {
    final model = modelPullStep(caps, isMacOS: isMacOS);
    if (model != null) steps.add(model);
  }

  steps.addAll(agentInstallSteps(caps));

  if (includeMedia && !caps.hasMediaEngine) {
    steps.add(
      const SetupStep(
        action: SetupAction.installComfy,
        title: 'Install the media engine',
        detail: 'The software that generates images on this computer.',
        args: ['engine', 'install', 'comfyui'],
        isDownload: false,
      ),
    );
  }

  if (includeMedia &&
      !(caps.media.bundle(defaultMediaBundle)?.isComplete ?? false)) {
    steps.add(
      const SetupStep(
        action: SetupAction.pullMediaBundle,
        title: 'Download image models',
        detail: 'Model files for image generation — several GB.',
        args: ['engine', 'pull', defaultMediaBundle],
        isDownload: true,
      ),
    );
  }

  return steps;
}

/// The install step for the one agent a machine must have before anyone can
/// chat — the default assistant [kChatAgent] — or nothing when it's already
/// there.
///
/// Only the required one, on purpose. The extras (Codex, and Claude Code)
/// install quietly in the background once the user is in
/// ([BackgroundAgentInstaller]), so a first run never blocks on an assistant the
/// user didn't pick — and never on a whole vendor CLI's download. The app
/// installs it into `~/.grid` itself, needing no Homebrew and no admin rights,
/// so the one required step still runs on every OS.
///
/// It's [kChatAgent] that lands here because it is the one chat falls back to;
/// the background installer is the single place that knows how to fetch *any*
/// agent, Claude Code included, so the plan doesn't try to.
List<SetupStep> agentInstallSteps(NodeCapabilities caps) => [
  if (!caps.installedAgents.contains(kChatAgent))
    SetupStep(
      action: SetupAction.installAgent,
      title: 'Install ${kChatAgent.name}',
      detail: kChatAgent.tagline,
      args: const [],
      isDownload: false,
      agent: kChatAgent,
    ),
];

/// The model-download step for [caps], or null when a model is already on disk.
///
/// Shared by [buildSetupPlan] and the background downloader so both pull the
/// same model: the CLI catalog's pick ([NodeCapabilities.recommendedModel]),
/// falling back to [_fallbackModelSpec] so a node never ends up with an engine
/// but no model.
SetupStep? modelPullStep(NodeCapabilities caps, {bool? isMacOS}) {
  if (caps.hasModels) return null;
  final model = caps.recommendedModel;
  final spec = model?.label ?? _fallbackModelSpec(isMacOS: isMacOS);
  final display = model?.repoFile ?? spec;
  return SetupStep(
    action: SetupAction.pullModel,
    title: 'Download a model',
    detail: 'A ready-to-use AI model ($display) — can be several GB.',
    args: ['pull', spec],
    isDownload: true,
  );
}
