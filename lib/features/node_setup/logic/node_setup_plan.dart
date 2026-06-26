import 'dart:io';

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

// Default text model pulled when this node has no local GGUF and no external
// backend to serve through. Mirrors the CLI catalog labels (catalog.py),
// resolved by platform since Grid providers target Apple Silicon / NVIDIA.
// TODO(BE): the app shouldn't hardcode catalog labels — fetch them from
// `grid models list --catalog` once that output is stable, to avoid drift.
const _appleSiliconModel = 'qwen36-35b-a3b-mtp';
const _nvidiaModel = 'qwen36-27b-mtp';

/// Catalog label of the default text model for this platform.
String defaultModelSpec({bool? isMacOS}) =>
    (isMacOS ?? Platform.isMacOS) ? _appleSiliconModel : _nvidiaModel;

/// Decides the minimal sequence of steps to make this computer a usable node,
/// installing only what's missing (the "auto-detect, fill the gaps" flow). Pure
/// and side-effect free, so it's trivially testable. Steps run in list order;
/// the ComfyUI bundle download is sequenced after its install.
List<SetupStep> buildSetupPlan(
  NodeCapabilities caps, {
  bool? isMacOS,
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

  if (!caps.hasModels && !caps.hasExternalModels) {
    final spec = defaultModelSpec(isMacOS: isMacOS);
    steps.add(SetupStep(
      action: SetupAction.pullModel,
      title: 'Download a model ($spec)',
      detail: 'Several GB — served locally so this node can answer chat.',
      args: ['models', 'pull', spec],
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
