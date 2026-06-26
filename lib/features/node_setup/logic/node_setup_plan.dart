import 'node_capabilities.dart';

/// One install/download action in the node-setup sequence.
enum SetupAction { installLlama, pullModel, installComfy, pullMediaBundle }

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
  });

  final SetupAction action;
  final String title;
  final String detail;
  final List<String> args;
  final bool isDownload;
}

/// Default ComfyUI bundle so the media engine is usable right after install.
const defaultMediaBundle = 'image_generation';

/// Decides the minimal sequence of steps to make this computer a usable node,
/// installing only what's missing (the "auto-detect, fill the gaps" flow). Pure
/// and side-effect free, so it's trivially testable. Steps run in list order;
/// the ComfyUI bundle download is sequenced after its install. The model to pull
/// comes from [NodeCapabilities.recommendedModel] (the CLI catalog), never a
/// hardcoded id.
List<SetupStep> buildSetupPlan(
  NodeCapabilities caps, {
  bool includeMedia = true,
}) {
  final steps = <SetupStep>[];

  if (!caps.hasTextInference) {
    steps.add(const SetupStep(
      action: SetupAction.installLlama,
      title: 'Install the built-in engine (llama.cpp)',
      detail: 'Runs `grid llama.cpp install`.',
      args: ['llama.cpp', 'install'],
      isDownload: false,
    ));
  }

  final model = caps.recommendedModel;
  if (!caps.hasModels && !caps.hasExternalModels && model != null) {
    steps.add(SetupStep(
      action: SetupAction.pullModel,
      title: 'Download a model (${model.label})',
      detail: 'From the recommended catalog — ${model.repoFile}.',
      args: ['models', 'pull', model.label],
      isDownload: true,
    ));
  }

  if (includeMedia && !caps.hasMediaEngine) {
    steps.add(const SetupStep(
      action: SetupAction.installComfy,
      title: 'Install the media engine (ComfyUI)',
      detail: 'Runs `grid media install`.',
      args: ['media', 'install'],
      isDownload: false,
    ));
  }

  if (includeMedia &&
      !(caps.media.bundle(defaultMediaBundle)?.isComplete ?? false)) {
    steps.add(const SetupStep(
      action: SetupAction.pullMediaBundle,
      title: 'Download image models ($defaultMediaBundle)',
      detail: 'Several GB of model files for ComfyUI image generation.',
      args: ['media', 'pull', defaultMediaBundle],
      isDownload: true,
    ));
  }

  return steps;
}
