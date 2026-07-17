import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/grid_overview_provider.dart';
import 'grid_overview_widgets.dart';

/// Live `GET {relayBaseUrl}/grid/overview` headline stats for the open grid.
/// Owns the single loading/error indicator for the overview — the Models and
/// Nodes sections stay quiet until the data resolves, so the pane never shows
/// two spinners at once.
class GridStatsSection extends ConsumerWidget {
  const GridStatsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(gridOverviewProvider)
        .when(
          loading: () => const OverviewMessage(
            icon: Icons.cloud_sync_outlined,
            text: 'Loading grid overview…',
          ),
          error: (err, _) =>
              OverviewMessage(icon: Icons.cloud_off_outlined, text: '$err'),
          data: (overview) => StatsBar(stats: overview.stats),
        );
  }
}

/// At-a-glance chips for what the grid can actually do — Chat when it serves
/// text models, Images / Video when a media (comfyui) provider is online. This
/// is the only place a media capability surfaces in the overview, since it never
/// appears in the Models list. Hidden until at least one capability resolves.
class GridCapabilitiesSection extends ConsumerWidget {
  const GridCapabilitiesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Chat only when a real text model is served — a comfyui media capability
    // can surface in the model list, so counting it as "Chat" would mislabel a
    // media-only grid. See [gridHasChatProvider].
    final hasChat = ref.watch(gridHasChatProvider);
    final media = ref.watch(gridMediaCapabilitiesProvider);
    final chips = <Widget>[
      if (hasChat)
        const CapabilityChip(icon: Icons.chat_bubble_outline, label: 'Chat'),
      if (media.image)
        const CapabilityChip(icon: Icons.image_outlined, label: 'Images'),
      if (media.video)
        const CapabilityChip(icon: Icons.movie_outlined, label: 'Video'),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    // Sits tight under the meta line as one more fact about the grid, in the
    // same register — it used to float in a gap of its own between the stats
    // card and the action card, anchored to nothing.
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'This grid can',
            style: kGridText.copyWith(
              fontSize: 12.5,
              color: AppPalette.textFaint,
            ),
          ),
          ...chips,
        ],
      ),
    );
  }
}

/// The grid's Nodes section — the machines pooling compute to serve it. Renders
/// only once the overview resolves with at least one node; [GridStatsSection]
/// above owns the shared loading/error state, so this stays silent until then.
class GridNodesSection extends ConsumerWidget {
  const GridNodesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes =
        ref.watch(gridOverviewProvider).asData?.value.nodes ??
        const <OverviewNode>[];
    if (nodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        SectionHeading(
          title: 'Nodes',
          subtitle:
              'Independent machines pooling their compute to serve this grid.',
          count: nodes.length,
        ),
        const SizedBox(height: 12),
        // Same shape as Models above — one card, hairline-separated.
        TileGroup(children: [for (final n in nodes) NodeTile(node: n)]),
      ],
    );
  }
}

/// The grid's Models section — one copyable tile per model the grid serves.
/// Rich tiles (with a Chat/media kind) when the relay overview details them,
/// otherwise plain id tiles from `/models`. Hidden when the grid serves none.
class GridModelsSection extends ConsumerWidget {
  const GridModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(gridModelsProvider);
    if (models.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        SectionHeading(
          title: 'Models',
          subtitle: 'Copy a model ID to use it with the API above.',
          // The count belongs on the heading now that the stats bar no longer
          // announces it in 24pt above.
          count: models.length,
        ),
        const SizedBox(height: 12),
        // One card, hairline-separated — not one card per model. See [TileGroup].
        TileGroup(children: [for (final m in models) ModelTile(model: m)]),
      ],
    );
  }
}
