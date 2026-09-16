/// What a paired phone is told about a grid's live state.
///
/// The phone has no grid credentials and never will — `credentials.toml` holds a
/// bearer token per grid and the pairing host reads four fields of it and stops
/// (see `mobile_rpc_service.dart`). So the phone cannot call
/// `GET {relay}/grid/overview` for itself: this computer calls it and sends back
/// a projection.
///
/// **The projection is display-ready strings, not the relay's payload.** Every
/// figure on that screen is formatted by a rule this repo already owns —
/// [formatVram] switching to TB past 1024, [formatThroughput] refusing decimals
/// on an estimate, [nodeOverviewSpecs] deciding which facts a machine's line
/// carries. A phone shipping its own copy of those rules is a second
/// implementation that drifts on the next change, and the two apps are then
/// quietly describing the same machine differently. The phone gets the words and
/// lays them out; the fractions come with them because a bar is geometry, not
/// prose.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/copy/plural.dart';
import '../../../shared/layouts/widgets/memory_split_bar.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/grid_power_provider.dart';
import '../../network/logic/node_display.dart';

/// The live overview of [gridId] as the phone is shown it, or null when this
/// computer could not get one.
///
/// Null rather than a failure: the grid detail the phone already had — which
/// grid, who it is signed in as, what this computer is serving to it — is read
/// off disk and is still true when the relay is unreachable. A screen that
/// refused to open because a network call failed would hide the half that never
/// needed the network.
Future<Map<String, Object?>?> phoneGridOverview(Ref ref, String gridId) async {
  try {
    return phoneOverviewProjection(
      await ref.read(gridOverviewForProvider(gridId).future),
    );
  } on Object {
    return null;
  }
}

/// [overview] as the phone's payload. Pure, so the shape the two apps agree on
/// is checked without a relay.
Map<String, Object?> phoneOverviewProjection(GridOverview overview) {
  final models = distinctOverviewModels([
    for (final model in overview.models)
      if (model.id != kAutoModelId) model,
  ]);
  final nodes = sortNodesByPower([
    for (final node in overview.nodes)
      if (node.online) node,
  ]);
  final power = gridPowerFrom(
    overview.nodes,
    models.length,
    capacity: overview.stats.concurrentCapacity,
    gridAnswered: overview.answered,
  );
  return {
    'meta': _meta(overview.stats, models.length),
    'can': _capabilities(models, overview.nodes),
    'models': [for (final model in models) _model(model)],
    'power': _power(power, nodes),
    // Every node, not just the online ones: the bar and the power figures are
    // about what the grid can do *now*, but the list is who is on it, and a
    // machine that went to sleep disappearing from the phone reads as a machine
    // that left the grid.
    'nodes': [for (final node in sortNodesByPower(overview.nodes)) _node(node)],
  };
}

/// "3 models · 4 nodes · 99.9% uptime", as its pieces.
///
/// Counted off the resolved model list rather than `stats.models`, which the
/// relay reports as 0 on a grid whose models it doesn't detail — the same reason
/// the desktop's own meta line does it (see `StatsBar`).
List<String> _meta(GridStats stats, int models) {
  final count = models > 0 ? models : stats.models;
  return [
    '$count ${plural(count, 'model')}',
    '${stats.nodes} ${plural(stats.nodes, 'node')}',
    if (stats.uptimePct case final pct?) '${_trim(pct)}% uptime',
  ];
}

/// The "This grid can …" chips, already labelled. Chat only for a real text
/// model, so a media-only or routing-only grid doesn't claim it.
List<Map<String, Object?>> _capabilities(
  List<OverviewModel> models,
  List<OverviewNode> nodes,
) {
  final media = gridMediaCapabilitiesFrom([
    for (final node in nodes) ...node.models,
  ]);
  return [
    if (models.any((m) => isRealChatModel(m.id)))
      {'icon': 'chat', 'label': 'Chat'},
    if (media.image) {'icon': 'image', 'label': 'Images'},
    if (media.video) {'icon': 'video', 'label': 'Video'},
  ];
}

/// One model row: the id to copy, what kind of thing it is, and which glyph
/// says so.
Map<String, Object?> _model(OverviewModel model) {
  final mediaLabel = mediaCapabilityLabel(model.id);
  return {
    'id': model.id,
    if (mediaLabel ?? model.modality case final kind?) 'kind': _cap(kind),
    'icon': mediaLabel == null
        ? 'chat'
        : isVideoCapability(model.id)
        ? 'video'
        : 'image',
  };
}

/// The grid's pooled hardware: the memory total, how it splits across machines,
/// and the figures under it. Null when no online node advertises any of it —
/// the phone then draws no power card rather than a card of dashes.
Map<String, Object?>? _power(GridPower power, List<OverviewNode> onlineNodes) {
  if (!power.hasSpecs) return null;
  final vram = power.vramGb;
  final slices = vram == null
      ? const <NodeSlice>[]
      : buildMemorySlices(onlineNodes, vram);
  return {
    if (vram != null && slices.isNotEmpty) ...{
      'memory': formatVram(vram),
      // The colour is left to the phone, which reads `sliceColor` of the index
      // out of the same shared palette this list was coloured from.
      'split': [
        for (final slice in slices)
          {
            'label': slice.label,
            'value': formatVram(slice.gb),
            'fraction': slice.fraction,
          },
      ],
    },
    'stats': [
      if (power.parallel case final parallel?)
        {
          'label': 'Runs at once',
          'value': '$parallel',
          'unit': plural(parallel, 'task'),
        },
      if (power.throughputTokS case final toks?)
        {'label': 'Speed', 'value': formatThroughput(toks), 'unit': 'tok/s'},
    ],
  };
}

/// One machine on the grid.
Map<String, Object?> _node(OverviewNode node) => {
  'name': node.name,
  'specs': nodeOverviewSpecs(node),
  'online': node.online,
  'plan': ?nodePlanLabel(node),
  'media': nodeIsMedia(node),
};

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Drop a trailing `.0` so `99.9 → "99.9"`, `8.0 → "8"`.
String _trim(num v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';
