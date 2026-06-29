import 'dart:io';

import 'node_capabilities.dart';
import 'node_setup_config.dart';

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

/// Fallback model used only when `grid catalog` is unavailable (CLI error, empty
/// target list, parse miss) — so a node never finishes with an engine but no
/// model. These are the catalog's own picks expressed as `repo:file`, which
/// `grid pull` parses directly without a catalog lookup, making them robust when
/// the catalog itself can't be read.
String _fallbackModelSpec({bool? isMacOS}) => (isMacOS ?? Platform.isMacOS)
    ? 'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf'
    : 'unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q5_K_XL.gguf';

/// Decides the minimal sequence of steps to make this computer a usable node,
/// installing only what's missing (the "auto-detect, fill the gaps" flow). Pure
/// and side-effect free, so it's trivially testable. Steps run in list order;
/// the ComfyUI bundle download is sequenced after its install. The model to pull
/// prefers [NodeCapabilities.recommendedModel] (the CLI catalog) and falls back
/// to [_fallbackModelSpec] so the model download is never silently skipped.
List<SetupStep> buildSetupPlan(
  NodeCapabilities caps, {
  bool includeMedia = kMediaSetupEnabled,
  bool? isMacOS,
}) {
  final steps = <SetupStep>[];

  if (!caps.hasTextInference) {
    steps.add(const SetupStep(
      action: SetupAction.installLlama,
      title: 'Install the built-in engine (llama.cpp)',
      detail: 'Runs `grid engine install llama.cpp`.',
      args: ['engine', 'install', 'llama.cpp'],
      isDownload: false,
    ));
  }

  // Always pull a model when this node has none and no external backend to
  // serve through — catalog label when known, otherwise a robust repo:file spec.
  if (!caps.hasModels && !caps.hasExternalModels) {
    final model = caps.recommendedModel;
    final spec = model?.label ?? _fallbackModelSpec(isMacOS: isMacOS);
    final display = model?.repoFile ?? spec;
    steps.add(SetupStep(
      action: SetupAction.pullModel,
      title: 'Download a model',
      detail: 'Downloading $display so this node can answer chat.',
      args: ['pull', spec],
      isDownload: true,
    ));
  }

  if (includeMedia && !caps.hasMediaEngine) {
    steps.add(const SetupStep(
      action: SetupAction.installComfy,
      title: 'Install the media engine (ComfyUI)',
      detail: 'Runs `grid engine install comfyui`.',
      args: ['engine', 'install', 'comfyui'],
      isDownload: false,
    ));
  }

  if (includeMedia &&
      !(caps.media.bundle(defaultMediaBundle)?.isComplete ?? false)) {
    steps.add(const SetupStep(
      action: SetupAction.pullMediaBundle,
      title: 'Download image models ($defaultMediaBundle)',
      detail: 'Several GB of model files for ComfyUI image generation.',
      args: ['engine', 'pull', defaultMediaBundle],
      isDownload: true,
    ));
  }

  return steps;
}
