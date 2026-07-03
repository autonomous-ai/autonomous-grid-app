import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/media_event.dart';

/// Presentation helpers for a grid node — pure so the node tile stays dumb and
/// these stay unit-tested. They turn the relay's raw fields (engine id, the
/// capability/model list) into the short, honest labels the overview shows.

const Map<String, String> _capabilityLabels = {
  kCapImageGenerate: 'Image generation',
  kCapImageEdit: 'Image editing',
  kCapI2V: 'Video',
};

/// Human label for a node's inference engine. Known engines get a tidy name;
/// anything else (MLX, vLLM, llama.cpp…) is shown as reported.
String nodeEngineLabel(String? engine) => switch ((engine ?? '').toLowerCase()) {
      'comfyui' => 'ComfyUI',
      'external' => 'External',
      '' => 'Engine',
      _ => engine!,
    };

/// One-line summary of what a node actually contributes, from the models it
/// advertises: media capabilities read as "Image generation, editing" / "Video";
/// text models collapse to "N chat models". Falls back to the node's primary
/// model when the list is empty.
String nodeRoleSummary(OverviewNode node) {
  final advertised = node.models.isNotEmpty
      ? node.models
      : [if ((node.model ?? '').isNotEmpty) node.model!];
  final media = [
    for (final m in advertised)
      if (_capabilityLabels.containsKey(m)) _capabilityLabels[m]!,
  ];
  if (media.isNotEmpty) return media.join(', ');
  final count = advertised.length;
  if (count == 0) return 'No models yet';
  return '$count chat model${count == 1 ? '' : 's'}';
}

/// Whether a node runs media generation (a comfyui provider) — the tile picks
/// its icon from this.
bool nodeIsMedia(OverviewNode node) =>
    (node.engine ?? '').toLowerCase() == 'comfyui' ||
    node.models.any(_capabilityLabels.containsKey);
