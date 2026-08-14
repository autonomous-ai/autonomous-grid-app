import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/media_event.dart';
import 'node_metrics.dart' show answeredSummary;

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

/// Whether a node is a subscription seat rather than a hardware node — it relays
/// to a hosted model on a plan tier (a codex/ChatGPT seat, ADR 0015), so it
/// brings a subscription, not local GPU memory. The signal is a non-empty
/// `plan_type`. The one predicate the memory pool and the plan label share, so
/// "does this machine contribute a plan or graphics memory?" is answered once.
bool nodeIsSubscription(OverviewNode node) =>
    (node.planType ?? '').trim().isNotEmpty;

/// A node's subscription tier as a display label — `free` → "Free plan" — or
/// null when it carries no plan (an ordinary hardware node). The tier names a
/// codex/ChatGPT seat's entitlement (ADR 0015), shown so a subscription-backed
/// node reads as what it is rather than an anonymous machine.
String? nodePlanLabel(OverviewNode node) {
  if (!nodeIsSubscription(node)) return null;
  final plan = node.planType!.trim();
  return '${plan[0].toUpperCase()}${plan.substring(1)} plan';
}

/// A short spec line for a node whose VRAM is unknown: engine and device class,
/// whichever of them says something ("doggi · GPU", "GPU", or empty).
///
/// The memory panel normally identifies a machine by its share of the grid's
/// GPU memory, but a relay can report `vram_gb: null` for every node — some
/// engines simply don't advertise it. Those grids fall back to a plain list,
/// and without this the rows are bare names with nothing distinguishing them.
///
/// Deliberately thin: `external` resolves to empty via [nodeEngineLabel]
/// because it's the app's own generic engine and means nothing to a user, and a
/// node reporting neither field gets an empty line rather than a placeholder.
String nodeSpecLine(OverviewNode node) {
  final engine = nodeEngineLabel(node.engine);
  final device = (node.deviceClass ?? '').toUpperCase();
  return [
    if (engine.isNotEmpty && engine != 'Engine') engine,
    if (device.isNotEmpty) device,
    ?nodePlanLabel(node),
  ].join(' · ');
}

/// What a node's graphics memory should be *called*: "RAM" on Apple Silicon,
/// which shares one unified pool, and "VRAM" on a discrete GPU (Windows, Linux,
/// Intel Mac) that has its own.
///
/// One rule, shared by every surface that prints the figure — the hardware panel
/// and the node list sit inches apart, and the same machine reading "192 GB RAM"
/// in one and "192 GB VRAM" in the other is a bug the eye catches immediately.
/// `macos-arm64` is the Apple Silicon tag the provider reports.
String nodeMemoryKind(OverviewNode node) =>
    (node.platform ?? '') == 'macos-arm64' ? 'RAM' : 'VRAM';

/// The operating system a node runs, from the relay's `platform` tag
/// (`macos-arm64` / `macos-x86_64` / `linux` / `windows`), or null when it
/// reported none — an older provider omits the field entirely.
///
/// The arch half is dropped: `x86_64` beside `M3 Ultra` tells a user nothing
/// they can act on, and the machine line already names the chip.
String? nodePlatformLabel(String? platform) {
  final value = (platform ?? '').toLowerCase();
  if (value.startsWith('macos')) return 'macOS';
  if (value.startsWith('linux')) return 'Linux';
  if (value.startsWith('windows')) return 'Windows';
  return null;
}

/// What kind of machine a node is: the chip when it named one ("M3 Ultra"),
/// otherwise the device the provider described itself as ("NVIDIA GeForce RTX
/// 4090 ×2"), then the OS, then what it serves — "M3 Ultra · macOS · 3 chat
/// models".
///
/// Chip *or* device, never both: on Apple Silicon the provider sends both and
/// they say the same thing twice ("Mac Studio · M3 Ultra"), while a GPU box
/// sends only the device. So the more specific of the two wins and the row keeps
/// its width for the numbers.
///
/// Empty when the node described neither itself nor its models — one honest
/// blank line rather than a row of placeholders.
String nodeMachineLine(OverviewNode node) {
  final chip = (node.chip ?? '').trim();
  final device = (node.device ?? '').trim();
  final hardware = chip.isNotEmpty ? chip : device;
  final role = nodeRoleSummary(node);
  return [
    if (hardware.isNotEmpty) hardware,
    ?nodePlatformLabel(node.platform),
    if (role != 'No models yet') role,
  ].join(' · ');
}

/// What a node has actually done, and how fast it does it — "24h: 1.2M tokens ·
/// 340 requests · ~34 tok/s · 4 parallel".
///
/// The work comes first because it is the question the list is opened to answer:
/// which of these machines is carrying the grid. GPU utilisation and free memory
/// used to lead this line and no longer appear on it — a single instantaneous
/// sample of a card says almost nothing about whether the machine is useful, and
/// on Apple Silicon (the bulk of this fleet) it is not reported at all, so the
/// line's most prominent figure was blank on most rows. Both readings are still
/// on the node dashboard, where they sit against a track that gives them scale.
///
/// The window is stated rather than implied: a cumulative count with no span
/// reads as all-time, which this is not — see [NodeAnswered].
///
/// **Every part is dropped when the node didn't report it**, so this line is
/// routinely short and sometimes empty: a relay too old to compute the answered
/// rollup sends none, and a grid whose providers don't advertise throughput
/// reports no speed. A `0 tok/s` standing in for "not measured" would libel a
/// working machine as an idle one — see the telemetry doc on [OverviewNode].
///
/// A measured zero is *kept*: `0 tokens` from a relay that did the sum is a real
/// statement about a machine that served nobody today, and only the absent ones
/// go.
String nodeActivityLine(OverviewNode node) {
  final speed = node.throughputTokS;
  final parallel = node.maxConcurrency;
  final answered = answeredSummary(node.answered);
  return [
    if (answered.isNotEmpty) answered,
    if (speed != null && speed > 0) '~${speed.round()} tok/s',
    if (parallel != null && parallel > 1) '$parallel parallel',
  ].join(' · ');
}

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

/// The relay's virtual auto-routing model id (ADR 0013). It is not a real,
/// answerable model — the relay advertises it (in `/models`, and in a grid's
/// model list once routing is on) even when no node is actually serving — so a
/// grid whose only model is `auto` has nothing to route to and must count as
/// empty, not "ready to chat". One constant so every empty-state check agrees.
const String kAutoModelId = 'auto';

/// One model id, in the form the app compares by.
///
/// Ids reach the app from three directions that disagree on case and spacing:
/// the curated catalog (`DeepSeek-V4-Flash-0731`), a node's own advertisement,
/// and the relay's normalised `public_id`, which is lowercased at the source.
/// Comparing any two of those raw would silently fail to match — and a failed
/// match here is invisible, because the answer is simply that the model has no
/// figures rather than an error anybody sees.
String modelKey(String id) => id.trim().toLowerCase();

/// The work every model on this grid has answered, summed across the machines
/// serving it and keyed by [modelKey].
///
/// A model is usually served by more than one node, and the relay reports the
/// rollup per node — so the grid-level figure exists nowhere in the payload and
/// has to be added up here. Windows are taken from the nodes themselves rather
/// than assumed; they are one setting on one relay, so they agree in practice,
/// and the first one seen is the one reported.
///
/// A model no node reported on is **absent from the result**, never a zero
/// entry: the caller has to be able to tell "nothing answered on it" from "no
/// relay measured it", and only the missing key carries the second meaning.
Map<String, NodeAnswered> answeredByModel(Iterable<OverviewNode> nodes) {
  final totals =
      <String, ({int inp, int cached, int out, int requests, int window})>{};
  for (final node in nodes) {
    final answered = node.answered;
    if (answered == null) continue;
    for (final entry in answered.byModel) {
      final key = modelKey(entry.model);
      if (key.isEmpty) continue;
      final running = totals[key];
      totals[key] = (
        inp: (running?.inp ?? 0) + entry.tokensIn,
        cached: (running?.cached ?? 0) + entry.tokensCached,
        out: (running?.out ?? 0) + entry.tokensOut,
        requests: (running?.requests ?? 0) + entry.requests,
        window: running?.window ?? answered.windowSeconds,
      );
    }
  }
  return {
    for (final MapEntry(key: id, value: t) in totals.entries)
      id: NodeAnswered(
        windowSeconds: t.window,
        tokensIn: t.inp,
        tokensCached: t.cached,
        tokensOut: t.out,
        requests: t.requests,
      ),
  };
}

/// Whether [id] is a real chat/text model the grid can actually answer with:
/// not a media (`comfyui:*`) capability that leaked into the model list, and not
/// the virtual `auto` router. The single predicate the app shares to decide
/// "does this grid have something to chat with?". See [mediaCapabilityLabel] and
/// [kAutoModelId].
bool isRealChatModel(String id) =>
    id != kAutoModelId && mediaCapabilityLabel(id) == null;

/// The models a grid can actually be asked something, out of the raw `/models`
/// list: [ids] as they came, or **empty** when the virtual `auto` router is all
/// there is.
///
/// A lone `auto` is an empty grid wearing a model's clothes — the relay
/// advertises it whenever routing is on, with nothing behind it to route to, so
/// listing it hands the user a model that answers nothing. Applied once at the
/// source (`networkModelsForProvider`) so the chat picker, the playground, the
/// messaging bot and every "no model yet" state agree. `auto` alongside real
/// models is kept: there it routes to one of them. See [kAutoModelId].
List<String> answerableModels(List<String> ids) =>
    ids.every((id) => id == kAutoModelId) ? const [] : ids;

/// Whether a model id is the image→video media capability — lets the model tile
/// pick a video glyph over the image one without re-parsing the id.
bool isVideoCapability(String id) => id == kCapI2V;
