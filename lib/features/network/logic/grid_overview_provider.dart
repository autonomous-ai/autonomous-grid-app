import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/media_event.dart';
import '../../../infrastructure/api/relay_api_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';
import 'network_models_provider.dart';
import 'node_display.dart';

/// Live overview of the selected grid, via `GET {relayBaseUrl}/grid/overview`
/// authorized with that grid's `access_token`. Auto-disposes and refetches
/// whenever the selected grid changes — i.e. every time you open a grid.
///
/// Throws [GridOverviewUnavailable] (never a raw socket error) so the detail
/// pane can render a clean "offline" state instead of a stack trace.
/// Overview for one specific grid, keyed by network id. A family so the grids
/// list can probe each grid's live state in parallel — independent of which one
/// is selected. The selected grid shares this exact cache via
/// [gridOverviewProvider], so the list dot and the detail header never disagree.
final gridOverviewForProvider = FutureProvider.autoDispose
    .family<GridOverview, String>((ref, networkId) async {
      final match = ref
          .watch(sessionProvider)
          .networks
          .where((n) => n.networkId == networkId);
      if (match.isEmpty) {
        throw const GridOverviewUnavailable('Grid not found.');
      }
      final network = match.first;
      final log = ref.read(commandLogProvider.notifier);
      final client = ref.read(relayApiClientProvider);
      final id = log.begin(
        CliCallKind.http,
        'GET ${network.relayBaseUrl}/grid/overview',
        detail: CommandDetail(authorized: network.relayApiKey.isNotEmpty),
      );
      try {
        final overview = await client.overview(
          baseUrl: network.relayBaseUrl,
          apiKey: network.relayApiKey,
        );
        log.finish(id, exitCode: 200);
        return overview;
      } on RelayUnavailable catch (e) {
        log.finish(
          id,
          exitCode: e.statusCode,
          error: e.statusCode == null ? '${e.cause ?? 'unreachable'}' : null,
        );
        throw GridOverviewUnavailable(
          e.statusCode == null
              ? 'Grid is unreachable right now.'
              : _reason(e.statusCode!),
        );
      }
    });

/// Overview for the currently selected grid — the detail pane's convenience view
/// over [gridOverviewForProvider].
final gridOverviewProvider = FutureProvider.autoDispose<GridOverview>((
  ref,
) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) {
    throw const GridOverviewUnavailable('No grid selected.');
  }
  return ref.watch(gridOverviewForProvider(network.networkId).future);
});

/// The last overview the selected grid resolved — null until the first one
/// lands, and the previous one while a refresh is in flight.
///
/// **Everything derived from the overview reads it through this**, never through
/// `ref.watch(gridOverviewProvider)` directly. Two reasons, both learned the hard
/// way:
///
/// - `.value`, not `.asData`: a poll flips the overview to loading, where
///   `asData` reads null — blanking the pill's numbers to zero for the whole
///   round-trip. The last good snapshot stays until a new one lands.
/// - selecting the snapshot *out* of the `AsyncValue` makes the loading→data
///   flip a change only when the grid itself changed. Watching the whole
///   `AsyncValue` meant every poll notified twice no matter what came back, so
///   the derived graph recomputed each cadence — and when that landed while a
///   screen was mounting its providers, a dependent invalidated itself mid-build,
///   which the framework reports as `setState() called during build`. Paired with
///   the value equality on [GridOverview], an unchanged grid now notifies nobody.
final gridOverviewSnapshot = gridOverviewProvider.select((a) => a.value);

/// Whether the first overview is still on its way — the only moment a panel is
/// allowed to draw a skeleton.
///
/// Selected, and guarded on `value == null`, for the reason above: the overview
/// is *polled*, so its `AsyncValue` goes loading→data on every round. A widget
/// watching the flag alone would flash its skeleton over figures it already has,
/// every cadence, which reads as the panel breaking rather than refreshing. This
/// flips exactly once, when the first payload lands.
final gridOverviewLoading = gridOverviewProvider.select(
  (a) => a.isLoading && a.value == null,
);

/// The grid's models to surface in the UI, richest source first: the relay
/// overview's detailed list (id + modality + pricing) when it has one, otherwise
/// plain ids from the OpenAI-style `/models`. Both the Models section (tiles) and
/// each node's "serving N" count read this one derived list, so the count and the
/// list can never disagree. Empty while loading or when the grid advertises none.
///
/// The virtual `auto` router (ADR 0013) is stripped here — the relay advertises
/// it even when no node is serving, so a grid whose only "model" is `auto` reads
/// as empty. Filtering at the source keeps every count, tile and empty-state
/// derived from this list honest. See [kAutoModelId].
final gridModelsProvider = Provider.autoDispose<List<OverviewModel>>((ref) {
  final rich =
      ref.watch(gridOverviewSnapshot)?.models ?? const <OverviewModel>[];
  final source = rich.isNotEmpty
      ? rich
      : [
          for (final id in ref.watch(servedModelIdsProvider))
            OverviewModel(id: id),
        ];
  return distinctOverviewModels([
    for (final model in source)
      if (model.id != kAutoModelId) model,
  ]);
});

/// What each of the grid's models can do — context window and vision — keyed by
/// [modelKey], for the surfaces that have a model *id* and need its capabilities.
///
/// Its own provider rather than a fold inside each card: the overview carries one
/// model list, and a dashboard of nine machines would otherwise rebuild the same
/// map nine times per poll. Empty — never null — while no overview has landed, so
/// a card asks and is told "nothing known about this model" rather than having to
/// handle a missing map.
///
/// **The node payload does not carry these fields.** `/grid/overview` reports
/// context length and vision on its `models` entries only; a node lists model
/// *ids*. This is the join, and it is the only one — see [modelCapabilities] for
/// why matching those ids raw would silently find nothing.
final gridModelCapabilitiesProvider = Provider<Map<String, ModelCapability>>((
  ref,
) {
  final models = ref.watch(gridOverviewSnapshot)?.models;
  return modelCapabilities(models ?? const <OverviewModel>[]);
});

/// Collapse duplicate model ids to ONE entry, keeping the richest row for each.
///
/// The relay's overview lists one entry per (provider, model), so a model served
/// by several providers with different pricing can appear multiple times. Tiles
/// and the model count should show a model once. "Richest" = has pricing, then
/// a known context length, then a definite vision flag — an entry that only
/// carries an id loses to one that can label the tile.
///
/// **Keyed by [modelKey], not by the raw id.** The ids reach the overview from
/// providers that disagree on case (`qwen/qwen3.8-27b` beside `Qwen/Qwen3.8-27B`
/// is one model advertised twice), and a raw key lets both through as separate
/// models. Every *figure* in the app is already keyed the folded way — see
/// [answeredByModel] — so the twins were not merely listed twice: they printed
/// the same rollup each, the count said one model more than the grid serves, and
/// a column of them summed past its own total.
List<OverviewModel> distinctOverviewModels(List<OverviewModel> models) {
  final best = <String, OverviewModel>{};
  for (final model in models) {
    final key = modelKey(model.id);
    final prev = best[key];
    if (prev == null || _isRicher(model, prev)) best[key] = model;
  }
  return best.values.toList(growable: false);
}

bool _isRicher(OverviewModel a, OverviewModel b) {
  int score(OverviewModel m) =>
      (m.pricing != null ? 1 : 0) +
      (m.contextLength != null ? 1 : 0) +
      (m.vision != null ? 1 : 0);
  return score(a) > score(b);
}

/// Whether the grid serves at least one real chat/text model. A media capability
/// (`comfyui:*`) and the virtual `auto` router don't count as "chat", so a
/// routing-only or media-only grid reads as empty. Shared by the overview
/// capability chips, the grid front-door setup card and the "How to use" guide so
/// they all decide "is this a chat grid?" the same way. See [isRealChatModel].
final gridHasChatProvider = Provider.autoDispose<bool>((ref) {
  return ref.watch(gridModelsProvider).any((m) => isRealChatModel(m.id));
});

/// Every chat/text model id the grid serves (media `comfyui:*` capabilities and
/// the virtual `auto` router filtered out). Lets a client list them all instead
/// of just the first — e.g. OpenClaw enumerates every model in its provider
/// config. Empty while loading or when the grid serves no chat model. See
/// [isRealChatModel].
final gridChatModelIdsProvider = Provider.autoDispose<List<String>>((ref) {
  return [
    for (final m in ref.watch(gridModelsProvider))
      if (isRealChatModel(m.id)) m.id,
  ];
});

/// What a grid can generate, read off its providers. Media (image/video) is a
/// node *capability* — it never appears in the model list — so this is the only
/// place the app learns a grid can make images. Used by the overview (to show
/// it) and the Playground (to offer it).
class GridMediaCapabilities {
  const GridMediaCapabilities({this.image = false, this.video = false});
  final bool image;
  final bool video;
  bool get any => image || video;
}

/// Derives media capabilities from the `comfyui:*` capabilities a grid's nodes
/// advertise. Generate and edit both count as "image".
GridMediaCapabilities gridMediaCapabilitiesFrom(Iterable<String> capabilities) {
  final caps = capabilities.toSet();
  return GridMediaCapabilities(
    image: caps.contains(kCapImageGenerate) || caps.contains(kCapImageEdit),
    video: caps.contains(kCapI2V),
  );
}

/// The selected grid's media capabilities, from its live overview nodes. Empty
/// (no image/video) while loading or when no media provider is online.
final gridMediaCapabilitiesProvider =
    Provider.autoDispose<GridMediaCapabilities>((ref) {
      final nodes =
          ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[];
      return gridMediaCapabilitiesFrom([
        for (final node in nodes) ...node.models,
      ]);
    });

class GridOverviewUnavailable implements Exception {
  const GridOverviewUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

String _reason(int status) => switch (status) {
  503 => 'No node is online for this grid right now.',
  401 || 403 => 'Not authorized for this grid.',
  _ => 'Grid overview unavailable (HTTP $status).',
};
