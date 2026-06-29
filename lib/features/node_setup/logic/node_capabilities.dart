import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import '../../provider_node/logic/backend_detector.dart';
import 'media_status.dart';
import 'model_catalog.dart';
import 'node_setup_config.dart';

/// A snapshot of what this computer can already do as a Grid node: which text
/// inference backends exist (Ollama / LM Studio / grid llama.cpp), whether the
/// ComfyUI media engine is installed, how many local GGUF models are on disk,
/// and the CLI-recommended model for this host. Drives `buildSetupPlan` — the
/// "first node" auto-setup only fills gaps.
class NodeCapabilities {
  const NodeCapabilities({
    required this.textBackends,
    required this.engine,
    required this.media,
    required this.localModelCount,
    this.recommendedModel,
  });

  final List<DetectedBackend> textBackends;
  final EngineStatus engine;
  final MediaStatus media;
  final int localModelCount;

  /// Default model to auto-download, from `grid catalog`. Null when the CLI
  /// recommends none for this machine (then no model is pulled).
  final CatalogModel? recommendedModel;

  /// External OpenAI-compatible servers already running (Ollama, LM Studio).
  List<DetectedBackend> get externalBackends =>
      textBackends.where((b) => b.isExternal).toList();

  /// An external backend that already advertises at least one model — this node
  /// can serve through it (`grid join --at`) without a local GGUF.
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
/// The host's recommended model from `grid models list --catalog`. The catalog
/// is static for the session, so this runs the command exactly once and caches
/// it — re-detecting capabilities never re-spawns the catalog lookup.
final recommendedModelProvider = FutureProvider<CatalogModel?>((ref) {
  return ModelCatalog(ref.read(gridCliServiceProvider)).defaultLanguageModel();
});

/// Probes this machine's node capabilities. Dependencies are read (not watched)
/// so an unrelated `localModels` refresh doesn't re-spawn the `grid` probes;
/// detection re-runs only when explicitly invalidated (after a setup run). The
/// per-detection cost is one `grid media status` plus HTTP backend probes — the
/// catalog comes cached from [recommendedModelProvider].
final nodeCapabilitiesProvider = FutureProvider<NodeCapabilities>((ref) async {
  final service = ref.read(gridCliServiceProvider);
  final modelCount = ref.read(localModelsProvider).length;
  final recommended = await ref.watch(recommendedModelProvider.future);

  // Probe text backends and (only when media setup is enabled) the media
  // engine concurrently. With media off we skip the `grid media status` spawn.
  final backendsFuture = BackendDetector().detect();
  final mediaFuture = kMediaSetupEnabled
      ? MediaDetector(service).detect()
      : Future<MediaStatus>.value(MediaStatus.notInstalled);

  return NodeCapabilities(
    textBackends: await backendsFuture,
    engine: EngineDetector().detect(),
    media: await mediaFuture,
    localModelCount: modelCount,
    recommendedModel: recommended,
  );
});
