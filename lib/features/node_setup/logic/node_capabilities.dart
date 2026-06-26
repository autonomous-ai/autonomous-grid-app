import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import '../../provider_node/logic/backend_detector.dart';
import 'media_status.dart';

/// A snapshot of what this computer can already do as a Grid node: which text
/// inference backends exist (Ollama / LM Studio / grid llama.cpp), whether the
/// ComfyUI media engine is installed, and how many local GGUF models are on
/// disk. Drives `buildSetupPlan` — the "first node" auto-setup only fills gaps.
class NodeCapabilities {
  const NodeCapabilities({
    required this.textBackends,
    required this.engine,
    required this.media,
    required this.localModelCount,
  });

  final List<DetectedBackend> textBackends;
  final EngineStatus engine;
  final MediaStatus media;
  final int localModelCount;

  /// External OpenAI-compatible servers already running (Ollama, LM Studio).
  List<DetectedBackend> get externalBackends =>
      textBackends.where((b) => b.isExternal).toList();

  /// An external backend that already advertises at least one model — this node
  /// can serve through it (`provider start --at`) without a local GGUF.
  bool get hasExternalModels =>
      externalBackends.any((b) => b.models.isNotEmpty);

  /// Any way to serve text: an external server, or the installed llama.cpp engine.
  bool get hasTextInference =>
      engine.llamaInstalled || externalBackends.isNotEmpty;

  bool get hasMediaEngine => media.installed;

  bool get hasModels => localModelCount > 0;

  /// Short label for the active text backend, for the capability summary.
  String? get textBackendLabel {
    if (externalBackends.isNotEmpty) return externalBackends.first.label;
    if (engine.llamaInstalled) return 'llama.cpp';
    return null;
  }
}

/// Probes every node capability of this machine, running the text-backend and
/// media-engine checks concurrently. Re-detected (invalidated) after a setup run.
final nodeCapabilitiesProvider = FutureProvider<NodeCapabilities>((ref) async {
  final service = ref.watch(gridCliServiceProvider);
  final modelCount = ref.watch(localModelsProvider).length;

  final backendsFuture = BackendDetector().detect();
  final mediaFuture = MediaDetector(service).detect();

  return NodeCapabilities(
    textBackends: await backendsFuture,
    engine: EngineDetector().detect(),
    media: await mediaFuture,
    localModelCount: modelCount,
  );
});
