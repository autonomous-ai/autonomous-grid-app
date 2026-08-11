import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/model_detail.dart';
import '../../../shared/theme/app_theme.dart';

/// The facts about a model, above its version picker: how popular it is, then
/// what it is and what it's for.
///
/// Split in two on purpose — popularity is two loose pills the way the sidebar
/// row shows the same numbers, while the specs you'd compare between models are
/// collected into one framed block so they read as a set.
class ModelDetailBadgeGrid extends StatelessWidget {
  const ModelDetailBadgeGrid({super.key, required this.detail});

  final ModelDetail detail;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final stats = <_BadgeItemData>[
      if (detail.likes > 0)
        _BadgeItemData(label: 'Likes', value: _formatCount(detail.likes)),
      if (detail.downloads > 0)
        _BadgeItemData(
          label: 'Downloads',
          value: _formatCount(detail.downloads),
        ),
    ];
    final specs = <_BadgeItemData>[
      if (detail.paramsB != null)
        _BadgeItemData(
          label: 'Parameters',
          value: '${detail.paramsB!.toStringAsFixed(1)}B',
        ),
      if (detail.architecture != null && detail.architecture!.isNotEmpty)
        _BadgeItemData(
          label: 'Architecture',
          value: _formatValue(detail.architecture!),
        ),
      if (detail.format != null)
        _BadgeItemData(label: 'Format', value: _formatValue(detail.format!)),
    ];
    final capability = detail.task != null && detail.task!.isNotEmpty
        ? _formatValue(detail.task!)
        : null;

    if (stats.isEmpty && specs.isEmpty && capability == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stats.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: stats.map((item) => _BadgeItem(data: item)).toList(),
          ),
        if (specs.isNotEmpty || capability != null) ...[
          if (stats.isNotEmpty) const SizedBox(height: 10),
          _SpecBlock(specs: specs, capability: capability),
        ],
      ],
    );
  }

  static String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }

  static String _formatValue(String value) {
    return value
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }
}

/// The model's specs as one framed block of two rows: what it is on top, what
/// it's for underneath, a hairline between them.
///
/// The specs are label-over-value columns rather than "Label: Value" pills —
/// three values on one baseline can be compared at a glance, which is the whole
/// reason to group them; a row of chips each carrying its own label reads as six
/// unrelated facts.
class _SpecBlock extends StatelessWidget {
  const _SpecBlock({required this.specs, required this.capability});

  final List<_BadgeItemData> specs;
  final String? capability;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        border: Border.all(color: AppCard.insetHair),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (specs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Wrap(
                spacing: 28,
                runSpacing: 10,
                children: [for (final s in specs) _SpecCell(data: s)],
              ),
            ),
          if (specs.isNotEmpty && capability != null)
            Divider(height: 1, thickness: 1, color: AppCard.insetHair),
          if (capability case final task?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: _SpecCell(
                data: _BadgeItemData(label: 'Capability', value: task),
              ),
            ),
        ],
      ),
    );
  }
}

/// One label-over-value column inside [_SpecBlock].
class _SpecCell extends StatelessWidget {
  const _SpecCell({required this.data});

  final _BadgeItemData data;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          data.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppPalette.textFaint,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          data.value,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _BadgeItemData {
  const _BadgeItemData({required this.label, required this.value});
  final String label;
  final String value;
}

class _BadgeItem extends StatelessWidget {
  const _BadgeItem({required this.data});

  final _BadgeItemData data;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${data.label}: ${data.value}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppPalette.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
