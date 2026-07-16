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
/// anything else (MLX, vLLM, llama.cpp…) is shown as reported. `external` is the
/// app's own generic engine — a meaningless label to a user — so it resolves to
/// empty and the node tile just drops it from the spec line.
String nodeEngineLabel(String? engine) =>
    switch ((engine ?? '').toLowerCase()) {
      'comfyui' => 'ComfyUI',
      'external' => '',
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

/// GPU-memory label for a node ("48 GB VRAM"), or null when it reports none — a
/// CPU-only node, or a provider that doesn't advertise VRAM. Prefers the node's
/// `vram_gb`, falling back to `vram_total_mb ÷ 1024`.
String? nodeVramLabel(OverviewNode node) {
  final gb =
      node.vramGb ??
      (node.vramTotalMb == null ? null : node.vramTotalMb! / 1024);
  if (gb == null || gb <= 0) return null;
  return '${_trimGb(gb)} GB VRAM';
}

/// Drop a trailing `.0` so `48.0 → "48"`, keep one decimal otherwise (`47.5`).
String _trimGb(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Whether a node runs media generation (a comfyui provider) — the tile picks
/// its icon from this.
bool nodeIsMedia(OverviewNode node) =>
    (node.engine ?? '').toLowerCase() == 'comfyui' ||
    node.models.any(_capabilityLabels.containsKey);

/// The media label for a model id when it's actually a comfyui media capability
/// that leaked into the model list (e.g. `comfyui:image_generation` → "Image
/// generation"), else null for a normal text model. One source so the node
/// summary and the model tile label media the same way instead of showing it as
/// a "Chat" model. See [kCapImageGenerate].
String? mediaCapabilityLabel(String id) => _capabilityLabels[id];

/// Whether a model id is the image→video media capability — lets the model tile
/// pick a video glyph over the image one without re-parsing the id.
bool isVideoCapability(String id) => id == kCapI2V;
