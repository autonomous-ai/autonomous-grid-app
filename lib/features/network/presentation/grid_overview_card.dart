import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/grid_overview_provider.dart';

const _mono = 'monospace';

/// Live `GET {relayBaseUrl}/grid/overview` snapshot for the open grid: headline
/// stats, the models it serves, and the nodes backing them.
class GridOverviewView extends ConsumerWidget {
  const GridOverviewView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(gridOverviewProvider).when(
          loading: () => const _OverviewMessage(
              icon: Icons.cloud_sync_outlined, text: 'Loading grid overview…'),
          error: (err, _) => _OverviewMessage(
              icon: Icons.cloud_off_outlined, text: '$err'),
          data: (overview) => _OverviewBody(overview: overview),
        );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.overview});
  final GridOverview overview;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatsBar(stats: overview.stats),
        if (overview.models.isNotEmpty) ...[
          const SizedBox(height: 24),
          const _SectionHeading(
              title: 'Models',
              subtitle: 'Pick a model by its id — each is priced per use.'),
          const SizedBox(height: 14),
          for (final m in overview.models) ...[
            _ModelTile(model: m),
            const SizedBox(height: 10),
          ],
        ],
        if (overview.nodes.isNotEmpty) ...[
          const SizedBox(height: 14),
          const _SectionHeading(
              title: 'Nodes',
              subtitle:
                  'Independent machines pooling their compute to serve this grid.'),
          const SizedBox(height: 14),
          for (final n in overview.nodes) ...[
            _NodeTile(node: n),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Pricing and stats are placeholders, pending the managed layer.',
            style: TextStyle(
                fontFamily: _mono, fontSize: 12, color: AppPalette.textFaint),
          ),
        ),
      ],
    );
  }
}

class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.stats});
  final GridStats stats;

  @override
  Widget build(BuildContext context) {
    final uptime = stats.uptimePct == null ? '—' : '${_trim(stats.uptimePct!)}%';
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _StatCell(label: 'MODELS', value: '${stats.models}'),
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
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: child,
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model});
  final OverviewModel model;

  @override
  Widget build(BuildContext context) {
    final p = model.pricing;
    final price = p == null
        ? null
        : '\$${_trim(p.inputPer1m ?? 0)} / \$${_trim(p.outputPer1m ?? 0)}';
    return _Card(
      child: Row(
        children: [
          const _TileIcon(icon: Icons.chat_bubble_outline, accent: true),
          const SizedBox(width: 14),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(model.id,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: _mono,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.textPrimary)),
                ),
                if (model.modality != null) ...[
                  const SizedBox(width: 10),
                  _Pill(text: _cap(model.modality!)),
                ],
              ],
            ),
          ),
          if (price != null) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(price,
                    style: const TextStyle(
                        fontFamily: _mono,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.textPrimary)),
                const SizedBox(height: 2),
                const Text('per 1M in / out',
                    style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 11.5,
                        color: AppPalette.textFaint)),
              ],
            ),
          ],
          const SizedBox(width: 12),
          _CopyIdChip(id: model.id),
        ],
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node});
  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    final spec = [
      if (node.device != null) node.device!,
      if (node.memoryGb != null) '${node.memoryGb} GB',
      if (node.model != null) node.model!,
    ].join(' · ');
    return _Card(
      child: Row(
        children: [
          const _TileIcon(icon: Icons.dns_outlined, accent: false),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(node.name,
                    style: const TextStyle(
                        fontFamily: _mono,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.textPrimary)),
                if (spec.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(spec,
                      style: const TextStyle(
                          fontFamily: _mono,
                          fontSize: 12.5,
                          color: AppPalette.textSecondary)),
                ],
              ],
            ),
          ),
          if (node.engine != null) ...[
            const SizedBox(width: 10),
            _Pill(text: node.engine!, accent: true),
          ],
          if (node.throughputTokS != null) ...[
            const SizedBox(width: 12),
            Text('~${node.throughputTokS!.round()} tok/s',
                style: const TextStyle(
                    fontFamily: _mono,
                    fontSize: 13,
                    color: AppPalette.textSecondary)),
          ],
          const SizedBox(width: 10),
          StatusDot(
              color: node.online ? AppPalette.online : AppPalette.offline,
              size: 9),
        ],
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.accent});
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accent ? AppPalette.accent : AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon,
          size: 20, color: accent ? Colors.white : AppPalette.textSecondary),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.accent = false});
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? AppPalette.accent : AppPalette.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? color.withValues(alpha: 0.16) : AppPalette.cardBgHover,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontFamily: _mono,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }
}

class _CopyIdChip extends StatelessWidget {
  const _CopyIdChip({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.cardBgHover,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          Clipboard.setData(ClipboardData(text: id));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Copied'), duration: Duration(seconds: 1)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(id,
                  style: const TextStyle(
                      fontFamily: _mono,
                      fontSize: 12.5,
                      color: AppPalette.textPrimary)),
              const SizedBox(width: 8),
              const Text('COPY',
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

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Drop a trailing `.0` so `99.9 → "99.9"`, `8.0 → "8"`, `0.0 → "0"`.
String _trim(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : '$v';
