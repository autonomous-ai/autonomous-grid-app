import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/grid_overview_provider.dart';
import '../logic/node_display.dart';

const _mono = 'monospace';

/// Live `GET {relayBaseUrl}/grid/overview` headline stats for the open grid.
/// Owns the single loading/error indicator for the overview — the Models and
/// Nodes sections stay quiet until the data resolves, so the pane never shows
/// two spinners at once.
class GridStatsSection extends ConsumerWidget {
  const GridStatsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(gridOverviewProvider).when(
          loading: () => const _OverviewMessage(
              icon: Icons.cloud_sync_outlined, text: 'Loading grid overview…'),
          error: (err, _) =>
              _OverviewMessage(icon: Icons.cloud_off_outlined, text: '$err'),
          data: (overview) => _StatsBar(stats: overview.stats),
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
    // media-only grid. See [mediaCapabilityLabel].
    final hasChat = ref
        .watch(gridModelsProvider)
        .any((m) => mediaCapabilityLabel(m.id) == null);
    final media = ref.watch(gridMediaCapabilitiesProvider);
    final chips = <Widget>[
      if (hasChat)
        const _CapabilityChip(icon: Icons.chat_bubble_outline, label: 'Chat'),
      if (media.image)
        const _CapabilityChip(icon: Icons.image_outlined, label: 'Images'),
      if (media.video)
        const _CapabilityChip(icon: Icons.movie_outlined, label: 'Video'),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('This grid can',
              style: TextStyle(
                  fontFamily: _mono, fontSize: 12.5, color: AppPalette.textFaint)),
          ...chips,
        ],
      ),
    );
  }
}

/// A single capability chip: an accent icon plus its label.
class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppPalette.accent),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  fontFamily: _mono,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary)),
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
    final nodes = ref.watch(gridOverviewProvider).asData?.value.nodes ??
        const <OverviewNode>[];
    if (nodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        const _SectionHeading(
            title: 'Nodes',
            subtitle:
                'Independent machines pooling their compute to serve this grid.'),
        const SizedBox(height: 14),
        for (final n in nodes) ...[
          _NodeTile(node: n),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _StatsBar extends ConsumerWidget {
  const _StatsBar({required this.stats});
  final GridStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uptime = stats.uptimePct == null ? '—' : '${_trim(stats.uptimePct!)}%';
    // The overview's own `stats.models` can lag at 0 when the relay doesn't
    // detail its models — trust the list we actually resolved (overview or
    // `/models`) whenever it has entries, so the headline matches the section.
    final resolved = ref.watch(gridModelsProvider).length;
    final models = resolved > 0 ? resolved : stats.models;
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _StatCell(label: 'MODELS', value: '$models'),
            const VerticalDivider(width: 1),
            _StatCell(label: 'NODES', value: '${stats.nodes}'),
            const VerticalDivider(width: 1),
            _StatCell(label: 'UPTIME', value: uptime),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: AppPalette.textFaint)),
            const SizedBox(height: 8),
            Text(value,
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textPrimary)),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontFamily: _mono,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary)),
        const SizedBox(height: 8),
        Text(subtitle,
            style: const TextStyle(
                fontFamily: _mono,
                fontSize: 13,
                color: AppPalette.textSecondary)),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: child,
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
        const _SectionHeading(
            title: 'Models',
            subtitle: 'Copy a model ID to use it with the API above.'),
        const SizedBox(height: 14),
        for (final m in models) ...[
          _ModelTile(model: m),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One compact model row: a modality-aware glyph, the copyable id, its kind
/// (Chat, or the media label when a comfyui capability surfaces in the list),
/// and the Copy action. Kept dense so a grid's models read as a tight list, not
/// a stack of oversized cards. No token price — grids are usually free and it
/// reads as noise ($0 / $0 / 1M); media has no per-token price at all.
class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model});
  final OverviewModel model;

  @override
  Widget build(BuildContext context) {
    // A comfyui media capability (image/video) can surface in the model list —
    // label it as media with an image/video glyph instead of the default
    // "Chat". See [mediaCapabilityLabel].
    final mediaLabel = mediaCapabilityLabel(model.id);
    final pill =
        mediaLabel ?? (model.modality == null ? null : _cap(model.modality!));
    final icon = mediaLabel == null
        ? Icons.chat_bubble_outline
        : isVideoCapability(model.id)
            ? Icons.movie_outlined
            : Icons.image_outlined;
    return _Card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          _TileIcon(icon: icon, accent: true, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(model.id,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary)),
          ),
          if (pill != null) ...[
            const SizedBox(width: 10),
            _Pill(text: pill),
          ],
          const SizedBox(width: 10),
          _CopyChip(id: model.id),
        ],
      ),
    );
  }
}

/// One node row — what each machine actually contributes. Unlike the old tile
/// (which mislabelled every node "Serving N models" grid-wide), this reads the
/// node's own fields: its engine, what it does (chat vs image/video), how much
/// it hardware it brings, and how many requests it runs in parallel.
class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node});
  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    final media = nodeIsMedia(node);
    final specs = <String>[
      nodeEngineLabel(node.engine),
      if ((node.deviceClass ?? '').isNotEmpty) node.deviceClass!.toUpperCase(),
      nodeRoleSummary(node),
      if ((node.maxConcurrency ?? 0) > 1) '${node.maxConcurrency} parallel',
      if (node.throughputTokS != null) '~${node.throughputTokS!.round()} tok/s',
    ];
    return _Card(
      child: Row(
        children: [
          _TileIcon(
            icon: media ? Icons.auto_awesome_outlined : Icons.dns_outlined,
            accent: false,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(node.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: _mono,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.textPrimary)),
                const SizedBox(height: 3),
                Text(specs.join('  ·  '),
                    style: const TextStyle(
                        fontFamily: _mono,
                        fontSize: 12,
                        color: AppPalette.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _OnlineTag(online: node.online),
        ],
      ),
    );
  }
}

/// Compact online/offline status, dot plus word, on a node row.
class _OnlineTag extends StatelessWidget {
  const _OnlineTag({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppPalette.online : AppPalette.offline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 8),
        const SizedBox(width: 6),
        Text(online ? 'Online' : 'Offline',
            style: TextStyle(
                fontFamily: _mono,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color)),
      ],
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.accent, this.size = 32});
  final IconData icon;
  final bool accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent ? AppPalette.accent : AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon,
          size: size * 0.5,
          color: accent ? Colors.white : AppPalette.textSecondary),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(
              fontFamily: _mono,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textSecondary)),
    );
  }
}

/// Small "Copy" pill on a model tile — copies the model's exact id (the id is
/// already the tile's title, so the pill stays a lean action, not a repeat).
class _CopyChip extends StatelessWidget {
  const _CopyChip({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.cardBgHover,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _copyToClipboard(context, id),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy_rounded, size: 13, color: AppPalette.accent),
              SizedBox(width: 6),
              Text('Copy',
                  style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: AppPalette.accent)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewMessage extends StatelessWidget {
  const _OverviewMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppPalette.textFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 13,
                    color: AppPalette.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// Copy [text] to the clipboard and confirm with a brief snackbar. Shared by the
/// model-id chip and the per-node model list so the "copy + toast" is defined once.
void _copyToClipboard(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
  );
}

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Drop a trailing `.0` so `99.9 → "99.9"`, `8.0 → "8"`, `0.0 → "0"`.
String _trim(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : '$v';
