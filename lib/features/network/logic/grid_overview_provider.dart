import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/media_event.dart';
import '../../../infrastructure/state/models/network_credential.dart';
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
  final match =
      ref.watch(sessionProvider).networks.where((n) => n.networkId == networkId);
  if (match.isEmpty) {
    throw const GridOverviewUnavailable('Grid not found.');
  }
  return _fetchOverview(match.first);
});

/// Overview for the currently selected grid — the detail pane's convenience view
/// over [gridOverviewForProvider].
final gridOverviewProvider =
    FutureProvider.autoDispose<GridOverview>((ref) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) {
    throw const GridOverviewUnavailable('No grid selected.');
  }
  return ref.watch(gridOverviewForProvider(network.networkId).future);
});

/// The grid's models to surface in the UI, richest source first: the relay
/// overview's detailed list (id + modality + pricing) when it has one, otherwise
/// plain ids from the OpenAI-style `/models`. Both the Models section (tiles) and
/// each node's "serving N" count read this one derived list, so the count and the
/// list can never disagree. Empty while loading or when the grid advertises none.
final gridModelsProvider = Provider.autoDispose<List<OverviewModel>>((ref) {
  final rich = ref.watch(gridOverviewProvider).asData?.value.models ??
      const <OverviewModel>[];
  if (rich.isNotEmpty) return rich;
  final ids = ref.watch(networkModelsProvider).asData?.value ?? const [];
  return [for (final id in ids) OverviewModel(id: id)];
});

/// Whether the grid serves at least one real chat/text model. A media capability
/// (`comfyui:*`) can leak into the model list, so those don't count as "chat".
/// Shared by the overview capability chips and the "How to use" guide so both
/// decide "is this a chat grid?" the same way (and the guide can hide chat setup
/// on a media-only grid). See [mediaCapabilityLabel].
final gridHasChatProvider = Provider.autoDispose<bool>((ref) {
  return ref
      .watch(gridModelsProvider)
      .any((m) => mediaCapabilityLabel(m.id) == null);
});

/// Every chat/text model id the grid serves (media `comfyui:*` capabilities
/// filtered out). Lets a client list them all instead of just the first — e.g.
/// OpenClaw enumerates every model in its provider config. Empty while loading
/// or when the grid serves no chat model. See [mediaCapabilityLabel].
final gridChatModelIdsProvider = Provider.autoDispose<List<String>>((ref) {
  return [
    for (final m in ref.watch(gridModelsProvider))
      if (mediaCapabilityLabel(m.id) == null) m.id,
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
  final nodes = ref.watch(gridOverviewProvider).asData?.value.nodes ??
      const <OverviewNode>[];
  return gridMediaCapabilitiesFrom([for (final node in nodes) ...node.models]);
});

class GridOverviewUnavailable implements Exception {
  const GridOverviewUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<GridOverview> _fetchOverview(NetworkCredential network) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .getUrl(Uri.parse('${network.relayBaseUrl}/grid/overview'))
        .timeout(const Duration(seconds: 4));
    request.headers
        .set(HttpHeaders.authorizationHeader, 'Bearer ${network.relayApiKey}');
    final response = await request.close().timeout(const Duration(seconds: 6));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw GridOverviewUnavailable(_reason(response.statusCode));
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const GridOverviewUnavailable('Malformed overview response.');
    }
    return GridOverview.fromJson(decoded.cast<String, dynamic>());
  } on GridOverviewUnavailable {
    rethrow;
  } on Object {
    throw const GridOverviewUnavailable('Grid is unreachable right now.');
  } finally {
    client.close(force: true);
  }
}

String _reason(int status) => switch (status) {
      503 => 'No node is online for this grid right now.',
      401 || 403 => 'Not authorized for this grid.',
      _ => 'Grid overview unavailable (HTTP $status).',
    };
