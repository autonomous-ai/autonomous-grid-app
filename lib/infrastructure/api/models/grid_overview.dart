import 'package:flutter/foundation.dart' show listEquals;

/// Parsed `GET {relayBaseUrl}/grid/overview` — the live snapshot a grid's relay
/// serves: headline stats, the models it advertises, and the nodes backing them.
/// Every field is null-tolerant so a partial/evolving payload never throws.
///
/// Every class here compares **by value**, and that is load-bearing, not tidiness.
/// The overview is re-fetched on a timer; without value equality each poll handed
/// Riverpod a brand-new object, so identity alone counted as "changed" and the
/// whole derived graph — models, media capabilities, grid power, online nodes —
/// recomputed and rebuilt every cadence for figures that hadn't moved. Worse, a
/// notification landing while a screen was mounting its providers made those
/// dependents invalidate mid-build, which is the `setState() during build` the
/// framework then reports against `UncontrolledProviderScope`. A grid that hasn't
/// changed now notifies nobody.
class GridOverview {
  const GridOverview({
    this.state,
    required this.stats,
    required this.models,
    required this.nodes,
    this.advertisesChatCompletions,
    this.advertisesResponses,
  });

  final String? state;
  final GridStats stats;
  final List<OverviewModel> models;
  final List<OverviewNode> nodes;

  /// Whether the grid serves at least one model that answers on
  /// `/v1/chat/completions`, and one that answers on `/v1/responses` — the two
  /// wire dialects a client can speak. Which agents can work here is derived
  /// from these (see `agentRunsOnGrid`).
  ///
  /// **Null means "the relay didn't say"**, never "no": a relay that predates
  /// the flags leaves them out, and reading absence as `false` would strand
  /// every user of an older grid. Only an explicit `false` rules a dialect out.
  final bool? advertisesChatCompletions;
  final bool? advertisesResponses;

  factory GridOverview.fromJson(Map<String, dynamic> j) {
    final grid = j['grid'];
    return GridOverview(
      state: grid is Map ? grid['state'] as String? : null,
      stats: GridStats.fromJson(
        j['stats'] is Map
            ? (j['stats'] as Map).cast<String, dynamic>()
            : const {},
      ),
      models: _list(j['models'], OverviewModel.fromJson),
      nodes: _list(j['nodes'], OverviewNode.fromJson),
      advertisesChatCompletions: _flag(j['advertises_chat_completions']),
      advertisesResponses: _flag(j['advertises_responses']),
    );
  }

  /// A tri-state flag: the boolean when the relay sent one, else null. Anything
  /// that isn't a bool (a string `"true"`, a number, a missing key) reads as
  /// unknown rather than throwing or guessing.
  static bool? _flag(Object? raw) => raw is bool ? raw : null;

  static List<T> _list<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parse,
  ) => raw is List
      ? raw
            .whereType<Map>()
            .map((m) => parse(m.cast<String, dynamic>()))
            .toList()
      : const [];

  @override
  bool operator ==(Object other) =>
      other is GridOverview &&
      other.state == state &&
      other.stats == stats &&
      listEquals(other.models, models) &&
      listEquals(other.nodes, nodes) &&
      other.advertisesChatCompletions == advertisesChatCompletions &&
      other.advertisesResponses == advertisesResponses;

  @override
  int get hashCode => Object.hash(
    state,
    stats,
    Object.hashAll(models),
    Object.hashAll(nodes),
    advertisesChatCompletions,
    advertisesResponses,
  );
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

  @override
  bool operator ==(Object other) =>
      other is GridStats &&
      other.models == models &&
      other.nodes == nodes &&
      other.concurrentCapacity == concurrentCapacity &&
      other.uptimePct == uptimePct;

  @override
  int get hashCode => Object.hash(models, nodes, concurrentCapacity, uptimePct);
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

  @override
  bool operator ==(Object other) =>
      other is OverviewModel &&
      other.id == id &&
      other.name == name &&
      other.maker == maker &&
      other.modality == modality &&
      other.contextLength == contextLength &&
      other.pricing == pricing &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(id, name, maker, modality, contextLength, pricing, status);
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

  @override
  bool operator ==(Object other) =>
      other is ModelPricing &&
      other.unit == unit &&
      other.inputPer1m == inputPer1m &&
      other.outputPer1m == outputPer1m;

  @override
  int get hashCode => Object.hash(unit, inputPer1m, outputPer1m);
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

  @override
  bool operator ==(Object other) =>
      other is OverviewNode &&
      other.name == name &&
      other.device == device &&
      other.chip == chip &&
      other.memoryGb == memoryGb &&
      other.vramGb == vramGb &&
      other.vramTotalMb == vramTotalMb &&
      other.deviceClass == deviceClass &&
      other.model == model &&
      listEquals(other.models, models) &&
      other.engine == engine &&
      other.throughputTokS == throughputTokS &&
      other.maxConcurrency == maxConcurrency &&
      other.online == online;

  @override
  int get hashCode => Object.hash(
    name,
    device,
    chip,
    memoryGb,
    vramGb,
    vramTotalMb,
    deviceClass,
    model,
    Object.hashAll(models),
    engine,
    throughputTokS,
    maxConcurrency,
    online,
  );
}
