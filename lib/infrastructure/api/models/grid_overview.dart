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
    this.advertisesMessages,
  });

  final String? state;
  final GridStats stats;
  final List<OverviewModel> models;
  final List<OverviewNode> nodes;

  /// Whether the grid serves at least one model that answers on
  /// `/v1/chat/completions`, one that answers on `/v1/responses`, and one that
  /// answers on Anthropic's `/v1/messages` — the three wire dialects a client
  /// can speak. Which clients and agents can work here is derived from these
  /// (see `agentRunsOnGrid`, `clientRunsOnGrid`).
  ///
  /// **Null means "the relay didn't say"**, never "no": a relay that predates
  /// the flags leaves them out, and reading absence as `false` would strand
  /// every user of an older grid. Only an explicit `false` rules a dialect out.
  final bool? advertisesChatCompletions;
  final bool? advertisesResponses;
  final bool? advertisesMessages;

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
      advertisesMessages: _flag(j['advertises_messages']),
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
      other.advertisesResponses == advertisesResponses &&
      other.advertisesMessages == advertisesMessages;

  @override
  int get hashCode => Object.hash(
    state,
    stats,
    Object.hashAll(models),
    Object.hashAll(nodes),
    advertisesChatCompletions,
    advertisesResponses,
    advertisesMessages,
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
    this.vision,
  });

  final String id;
  final String? name;
  final String? maker;
  final String? modality;
  final int? contextLength;
  final ModelPricing? pricing;
  final String? status;

  /// Whether the model can read attached images (vision chat). **Null means the
  /// relay didn't say** — an older relay omits it, and reading absence as
  /// `false` would misreport every model from one. Callers that need a definite
  /// answer decide what to do with unknown.
  final bool? vision;

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
    vision: j['vision'] is bool ? j['vision'] as bool : null,
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
      other.status == status &&
      other.vision == vision;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    maker,
    modality,
    contextLength,
    pricing,
    status,
    vision,
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

  @override
  bool operator ==(Object other) =>
      other is ModelPricing &&
      other.unit == unit &&
      other.inputPer1m == inputPer1m &&
      other.outputPer1m == outputPer1m;

  @override
  int get hashCode => Object.hash(unit, inputPer1m, outputPer1m);
}

/// One rate-limit window (primary/secondary) of a codex seat, from the relay's
/// `codex_rate_limits`. Percentages are 0–100; `windowMinutes` is the quota
/// period (43200 = 30d free, 10080 = 7d weekly on paid); `resetAt` is a Unix
/// epoch (seconds) and `resetAfterSeconds` the seconds until it rolls. All
/// null-tolerant — an evolving/absent payload never throws.
class CodexWindow {
  const CodexWindow({
    this.usedPercent,
    this.remainingPercent,
    this.windowMinutes,
    this.resetAt,
    this.resetAfterSeconds,
  });

  final int? usedPercent;
  final int? remainingPercent;
  final int? windowMinutes;
  final int? resetAt;
  final int? resetAfterSeconds;

  factory CodexWindow.fromJson(Map<String, dynamic> j) => CodexWindow(
    usedPercent: (j['used_percent'] as num?)?.toInt(),
    remainingPercent: (j['remaining_percent'] as num?)?.toInt(),
    windowMinutes: (j['window_minutes'] as num?)?.toInt(),
    resetAt: (j['reset_at'] as num?)?.toInt(),
    resetAfterSeconds: (j['reset_after_seconds'] as num?)?.toInt(),
  );

  @override
  bool operator ==(Object other) =>
      other is CodexWindow &&
      other.usedPercent == usedPercent &&
      other.remainingPercent == remainingPercent &&
      other.windowMinutes == windowMinutes &&
      other.resetAt == resetAt &&
      other.resetAfterSeconds == resetAfterSeconds;

  @override
  int get hashCode => Object.hash(
    usedPercent,
    remainingPercent,
    windowMinutes,
    resetAt,
    resetAfterSeconds,
  );
}

/// A codex seat's rate-limit snapshot the provider harvested from the vendor's
/// `x-codex-*` headers (relay `codex_rate_limits`). Only present on a node whose
/// `engine == 'codex'`; null for hardware nodes. `primary` is the main quota
/// window; `secondary` is a shorter window some tiers add.
class CodexRateLimits {
  const CodexRateLimits({
    this.planType,
    this.activeLimit,
    this.primary,
    this.secondary,
  });

  final String? planType;
  final String? activeLimit;
  final CodexWindow? primary;
  final CodexWindow? secondary;

  factory CodexRateLimits.fromJson(Map<String, dynamic> j) => CodexRateLimits(
    planType: j['plan_type'] as String?,
    activeLimit: j['active_limit'] as String?,
    primary: j['primary'] is Map
        ? CodexWindow.fromJson((j['primary'] as Map).cast<String, dynamic>())
        : null,
    secondary: j['secondary'] is Map
        ? CodexWindow.fromJson((j['secondary'] as Map).cast<String, dynamic>())
        : null,
  );

  @override
  bool operator ==(Object other) =>
      other is CodexRateLimits &&
      other.planType == planType &&
      other.activeLimit == activeLimit &&
      other.primary == primary &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(planType, activeLimit, primary, secondary);
}

/// What one model produced on one node inside the overview's rollup window —
/// the relay's `answered.by_model[]`.
/// The three token figures the relay reports for a stretch of work, and the
/// arithmetic that keeps them honest.
///
/// **`tokensCached` is part of `tokensIn`, never additional to it.** The relay's
/// settlement is explicit about this — it bills
/// `(in − cached)·input + cached·cache + out·output` — so a grand total is
/// [totalTokens] = in + out, and anything adding cache on top counts the cached
/// prefill twice. Use [freshInputTokens] for the "input" leg of a three-way
/// split, which is what makes the three legs add up to the total.
mixin AnsweredTokens {
  /// Tokens read. Includes [tokensCached].
  int get tokensIn;

  /// The share of [tokensIn] that came from a prompt cache — nearly free, and
  /// the reason input and output can't be one number.
  int get tokensCached;

  /// Tokens generated. Where the time actually goes.
  int get tokensOut;

  /// Input that was not served from cache — the leg a three-way split needs.
  int get freshInputTokens => tokensIn - tokensCached;

  /// Everything that passed through, counted once.
  int get totalTokens => tokensIn + tokensOut;
}

/// What one model produced on one node inside the overview's rollup window —
/// the relay's `answered.by_model[]`.
class AnsweredModel with AnsweredTokens {
  const AnsweredModel({
    required this.model,
    this.tokensIn = 0,
    this.tokensCached = 0,
    required this.tokensOut,
    required this.requests,
  });

  final String model;

  @override
  final int tokensIn;

  @override
  final int tokensCached;

  @override
  final int tokensOut;

  /// How many answered requests those tokens came from. Shown beside them
  /// because the token count alone can't tell 300 ordinary replies from three
  /// enormous ones.
  final int requests;

  factory AnsweredModel.fromJson(Map<String, dynamic> j) => AnsweredModel(
    model: '${j['model'] ?? ''}',
    tokensIn: (j['tokens_in'] as num?)?.toInt() ?? 0,
    tokensCached: (j['tokens_cached'] as num?)?.toInt() ?? 0,
    tokensOut: (j['tokens_out'] as num?)?.toInt() ?? 0,
    requests: (j['requests'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is AnsweredModel &&
      other.model == model &&
      other.tokensIn == tokensIn &&
      other.tokensCached == tokensCached &&
      other.tokensOut == tokensOut &&
      other.requests == requests;

  @override
  int get hashCode =>
      Object.hash(model, tokensIn, tokensCached, tokensOut, requests);
}

/// How much a node has answered lately: the totals, the per-model split, and
/// the span they cover.
///
/// **Present with zeros is not the same as absent.** A node the relay measured
/// and found idle sends real zeros here, and the dashboard prints `0` — a true
/// statement about a machine that served nothing today. A relay too old to
/// compute this, or one whose rollup has never succeeded, sends no `answered`
/// object at all and the field is null, which the dashboard prints as `—`. The
/// distinction is the whole reason this is a nullable object rather than a pair
/// of int fields defaulting to 0 — see the telemetry note on [OverviewNode].
class NodeAnswered with AnsweredTokens {
  const NodeAnswered({
    required this.windowSeconds,
    this.tokensIn = 0,
    this.tokensCached = 0,
    required this.tokensOut,
    required this.requests,
    this.byModel = const [],
  });

  /// The span these figures cover, as the relay reported it. Carried rather
  /// than assumed: the window is an operator knob, and a label hardcoded to
  /// "24h" would go quietly wrong the moment someone retuned it.
  final int windowSeconds;

  @override
  final int tokensIn;

  @override
  final int tokensCached;

  @override
  final int tokensOut;

  final int requests;

  /// The same totals split by model, biggest first. Empty on a node that
  /// answered nothing in the window.
  final List<AnsweredModel> byModel;

  factory NodeAnswered.fromJson(Map<String, dynamic> j) => NodeAnswered(
    windowSeconds: (j['window_seconds'] as num?)?.toInt() ?? 0,
    tokensIn: (j['tokens_in'] as num?)?.toInt() ?? 0,
    tokensCached: (j['tokens_cached'] as num?)?.toInt() ?? 0,
    tokensOut: (j['tokens_out'] as num?)?.toInt() ?? 0,
    requests: (j['requests'] as num?)?.toInt() ?? 0,
    byModel: j['by_model'] is List
        ? [
            for (final m in j['by_model'] as List)
              if (m is Map) AnsweredModel.fromJson(m.cast<String, dynamic>()),
          ]
        : const [],
  );

  @override
  bool operator ==(Object other) =>
      other is NodeAnswered &&
      other.windowSeconds == windowSeconds &&
      other.tokensIn == tokensIn &&
      other.tokensCached == tokensCached &&
      other.tokensOut == tokensOut &&
      other.requests == requests &&
      listEquals(other.byModel, byModel);

  @override
  int get hashCode => Object.hash(
    windowSeconds,
    tokensIn,
    tokensCached,
    tokensOut,
    requests,
    Object.hashAll(byModel),
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
    this.platform,
    this.throughputTokS,
    this.maxConcurrency,
    this.planType,
    this.codexRateLimits,
    this.vramUsedMb,
    this.gpuUtilPct,
    this.gpuTempC,
    this.gpuPowerW,
    this.gpuPowerLimitW,
    this.diskTotalGb,
    this.diskUsedGb,
    this.answered,
    required this.online,
  });

  final String name;
  final String? device;
  final String? chip;
  final int? memoryGb;

  /// The subscription tier a seat-backed node serves on — `free` / `plus` /
  /// `pro` from the relay's `plan_type` (a codex/ChatGPT subscription node, ADR
  /// 0015). Null for an ordinary hardware node that carries no plan.
  final String? planType;

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

  /// OS/arch the node reported: `macos-arm64` (Apple Silicon — unified memory,
  /// so its "GPU memory" is really RAM), `macos-x86_64` / `linux` / `windows`
  /// (discrete GPU with its own VRAM). Null on older providers that omit it.
  final String? platform;

  final double? throughputTokS;
  final int? maxConcurrency;
  final bool online;

  /// Live telemetry from the node's last heartbeat: GPU memory in use, GPU
  /// utilisation (0–100), die temperature in °C, power draw and the card's
  /// power cap in watts, and the model volume's size and usage in GB.
  ///
  /// **Each one is independently null, and null is not zero.** A Mac reports
  /// total VRAM but never utilisation or temperature (macOS exposes those only
  /// to a root `powermetrics`); a CPU-only box reports neither; a datacenter
  /// card reports all of them. Render nothing where a value is null — a `0%`
  /// standing in for "not measured" is indistinguishable from a genuinely idle
  /// node, which is the exact confusion this nullability exists to prevent.
  final double? vramUsedMb;
  final double? gpuUtilPct;
  final double? gpuTempC;
  final double? gpuPowerW;
  final double? gpuPowerLimitW;
  final double? diskTotalGb;
  final double? diskUsedGb;

  /// How much this node has answered inside the relay's rollup window. **Null
  /// means the relay didn't say** — an older master computes no such figure —
  /// and is rendered as unmeasured, never as an idle machine. See
  /// [NodeAnswered] for why zeros and null must stay distinguishable.
  final NodeAnswered? answered;

  /// The codex seat's rate-limit snapshot, when this node serves a codex engine
  /// (`engine == 'codex'`). Null for every other engine. Stale between the
  /// provider's served requests — the relay only refreshes it on a response/seed.
  final CodexRateLimits? codexRateLimits;

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
    platform: j['platform'] as String?,
    throughputTokS: (j['throughput_tok_s'] as num?)?.toDouble(),
    maxConcurrency: (j['max_concurrency'] as num?)?.toInt(),
    planType: j['plan_type'] as String?,
    codexRateLimits: j['codex_rate_limits'] is Map
        ? CodexRateLimits.fromJson(
            (j['codex_rate_limits'] as Map).cast<String, dynamic>(),
          )
        : null,
    vramUsedMb: (j['vram_used_mb'] as num?)?.toDouble(),
    gpuUtilPct: (j['gpu_util_pct'] as num?)?.toDouble(),
    gpuTempC: (j['gpu_temp_c'] as num?)?.toDouble(),
    gpuPowerW: (j['gpu_power_w'] as num?)?.toDouble(),
    gpuPowerLimitW: (j['gpu_power_limit_w'] as num?)?.toDouble(),
    diskTotalGb: (j['disk_total_gb'] as num?)?.toDouble(),
    diskUsedGb: (j['disk_used_gb'] as num?)?.toDouble(),
    answered: j['answered'] is Map
        ? NodeAnswered.fromJson((j['answered'] as Map).cast<String, dynamic>())
        : null,
    online: j['online'] == true,
  );

  /// GPU memory still free, in GB — the headroom a new model has to fit into.
  /// Null unless the node reported BOTH total and used: subtracting an absent
  /// figure from a present one would invent headroom nobody measured.
  double? get vramFreeGb {
    final total = vramTotalMb;
    final used = vramUsedMb;
    if (total == null || used == null) return null;
    return (total - used) / 1024;
  }

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
      other.platform == platform &&
      other.throughputTokS == throughputTokS &&
      other.maxConcurrency == maxConcurrency &&
      other.planType == planType &&
      other.codexRateLimits == codexRateLimits &&
      other.vramUsedMb == vramUsedMb &&
      other.gpuUtilPct == gpuUtilPct &&
      other.gpuTempC == gpuTempC &&
      other.gpuPowerW == gpuPowerW &&
      other.gpuPowerLimitW == gpuPowerLimitW &&
      other.diskTotalGb == diskTotalGb &&
      other.diskUsedGb == diskUsedGb &&
      other.answered == answered &&
      other.online == online;

  // `Object.hashAll` rather than `Object.hash`: the latter takes at most 20
  // positional arguments and the telemetry fields push this past that ceiling.
  @override
  int get hashCode => Object.hashAll([
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
    platform,
    throughputTokS,
    maxConcurrency,
    planType,
    codexRateLimits,
    vramUsedMb,
    gpuUtilPct,
    gpuTempC,
    gpuPowerW,
    gpuPowerLimitW,
    diskTotalGb,
    diskUsedGb,
    answered,
    online,
  ]);
}
