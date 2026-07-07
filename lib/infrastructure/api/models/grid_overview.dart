/// Parsed `GET {relayBaseUrl}/grid/overview` — the live snapshot a grid's relay
/// serves: headline stats, the models it advertises, and the nodes backing them.
/// Every field is null-tolerant so a partial/evolving payload never throws.
class GridOverview {
  const GridOverview({
    this.state,
    required this.stats,
    required this.models,
    required this.nodes,
  });

  final String? state;
  final GridStats stats;
  final List<OverviewModel> models;
  final List<OverviewNode> nodes;

  factory GridOverview.fromJson(Map<String, dynamic> j) {
    final grid = j['grid'];
    return GridOverview(
      state: grid is Map ? grid['state'] as String? : null,
      stats: GridStats.fromJson(
          j['stats'] is Map ? (j['stats'] as Map).cast<String, dynamic>() : const {}),
      models: _list(j['models'], OverviewModel.fromJson),
      nodes: _list(j['nodes'], OverviewNode.fromJson),
    );
  }

  static List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
      raw is List
          ? raw
              .whereType<Map>()
              .map((m) => parse(m.cast<String, dynamic>()))
              .toList()
          : const [];
}

class GridStats {
  const GridStats({
    required this.models,
    required this.nodes,
    this.concurrentCapacity,
    this.uptimePct,
  });

  final int models;
  final int nodes;
  final int? concurrentCapacity;
  final double? uptimePct;

  factory GridStats.fromJson(Map<String, dynamic> j) => GridStats(
        models: (j['models'] as num?)?.toInt() ?? 0,
        nodes: (j['nodes'] as num?)?.toInt() ?? 0,
        concurrentCapacity: (j['concurrent_capacity'] as num?)?.toInt(),
        uptimePct: (j['uptime_pct'] as num?)?.toDouble(),
      );
}

class OverviewModel {
  const OverviewModel({
    required this.id,
    this.name,
    this.maker,
    this.modality,
    this.contextLength,
    this.pricing,
    this.status,
  });

  final String id;
  final String? name;
  final String? maker;
  final String? modality;
  final int? contextLength;
  final ModelPricing? pricing;
  final String? status;

  factory OverviewModel.fromJson(Map<String, dynamic> j) => OverviewModel(
        id: '${j['id'] ?? ''}',
        name: j['name'] as String?,
        maker: j['maker'] as String?,
        modality: j['modality'] as String?,
        contextLength: (j['context_length'] as num?)?.toInt(),
        pricing: j['pricing'] is Map
            ? ModelPricing.fromJson((j['pricing'] as Map).cast<String, dynamic>())
            : null,
        status: j['status'] as String?,
      );
}

class ModelPricing {
  const ModelPricing({this.unit, this.inputPer1m, this.outputPer1m});

  final String? unit;
  final double? inputPer1m;
  final double? outputPer1m;

  factory ModelPricing.fromJson(Map<String, dynamic> j) => ModelPricing(
        unit: j['unit'] as String?,
        inputPer1m: (j['input_per_1m'] as num?)?.toDouble(),
        outputPer1m: (j['output_per_1m'] as num?)?.toDouble(),
      );
}

class OverviewNode {
  const OverviewNode({
    required this.name,
    this.device,
    this.chip,
    this.memoryGb,
    this.vramGb,
    this.vramTotalMb,
    this.deviceClass,
    this.model,
    this.models = const [],
    this.engine,
    this.throughputTokS,
    this.maxConcurrency,
    required this.online,
  });

  final String name;
  final String? device;
  final String? chip;
  final int? memoryGb;

  /// GPU memory the node brings, in GB. The relay's `vram_gb`; `vram_total_mb`
  /// is the raw fallback. Null on CPU-only nodes or providers that don't report
  /// it. Surfaced per node via `nodeVramLabel`.
  final double? vramGb;
  final double? vramTotalMb;

  final String? deviceClass;

  /// The node's primary served model/capability.
  final String? model;

  /// Every model or capability this node advertises — for a `comfyui` engine
  /// these are media capabilities like `comfyui:image_generation`. The media
  /// picker reads these since media capabilities never appear in the model list.
  final List<String> models;

  final String? engine;
  final double? throughputTokS;
  final int? maxConcurrency;
  final bool online;

  factory OverviewNode.fromJson(Map<String, dynamic> j) => OverviewNode(
        name: '${j['name'] ?? ''}',
        device: j['device'] as String?,
        chip: j['chip'] as String?,
        memoryGb: (j['memory_gb'] as num?)?.toInt(),
        vramGb: (j['vram_gb'] as num?)?.toDouble(),
        vramTotalMb: (j['vram_total_mb'] as num?)?.toDouble(),
        deviceClass: j['device_class'] as String?,
        model: j['model'] as String?,
        models: j['models'] is List
            ? [for (final m in j['models'] as List) '$m']
            : const [],
        engine: j['engine'] as String?,
        throughputTokS: (j['throughput_tok_s'] as num?)?.toDouble(),
        maxConcurrency: (j['max_concurrency'] as num?)?.toInt(),
        online: j['online'] == true,
      );
}
