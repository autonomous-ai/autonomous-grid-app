/// The live half of a grid's detail screen: what it can do, what it serves,
/// what it runs on.
///
/// The same reading order as the computer's own overview — facts, capability,
/// power, models, machines — because somebody who has seen one screen should
/// recognise the other. What changes is the shape: a phone gets stacked rows
/// where the desktop gets columns, and no hover, so anything that was only
/// reachable by pointing at it is reachable by tapping here.
///
/// The power card is next door in `grid_power_card.dart` — it is the one block
/// here with geometry of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_overview_view.dart';
import 'parts.dart';

/// "3 models · 4 nodes · 99.9% uptime", and what the grid can do under it.
class GridFacts extends StatelessWidget {
  const GridFacts({required this.meta, required this.can, super.key});

  /// The headline figures, already written.
  final List<String> meta;

  /// Chat / Images / Video, as far as this grid goes.
  final List<GridCapability> can;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (meta.isEmpty && can.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meta.isNotEmpty)
          Text(
            meta.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        if (can.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'This grid can',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textFaint,
                  ),
                ),
                for (final chip in can) _Capability(chip),
              ],
            ),
          ),
      ],
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability(this.chip);

  final GridCapability chip;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(gridGlyph(chip.icon), size: 14, color: AppPalette.accent),
        const SizedBox(width: 5),
        Text(chip.label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// One model the grid serves. The whole row copies the id, because a phone has
/// no hover to reveal a copy button with and the id is the only thing on this
/// row anybody wants.
class GridModelTile extends StatelessWidget {
  const GridModelTile(this.model, {super.key});

  /// The model.
  final GridModelRow model;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridListRow(
      onTap: () => _copy(context, model.id),
      child: Row(
        children: [
          Icon(gridGlyph(model.icon), size: 16, color: AppPalette.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                RowDetail([model.kind]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.copy_rounded, size: 16, color: AppPalette.textFaint),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied $id')));
  }
}

/// One machine on the grid: what it is called, what it brings, and whether it
/// is awake.
class GridNodeTile extends StatelessWidget {
  const GridNodeTile(this.node, {super.key});

  /// The machine.
  final GridNodeRow node;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridListRow(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: GridDot(live: node.online),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (node.plan.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      _Plan(node.plan),
                    ],
                  ],
                ),
                RowDetail(node.specs, maxLines: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The subscription tier on a seat-backed machine — a statement about it, not
/// something to tap, so it wears a tint rather than a button's fill.
class _Plan extends StatelessWidget {
  const _Plan(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: AppPalette.accent,
        ),
      ),
    );
  }
}

/// The glyph for a capability or modality the computer named.
///
/// Names cross the wire, not icons: the two apps would otherwise have to agree
/// on an icon font, and a phone shown a name it doesn't know draws the neutral
/// glyph instead of nothing.
IconData gridGlyph(String name) => switch (name) {
  'image' => Icons.image_outlined,
  'video' => Icons.movie_outlined,
  _ => Icons.chat_bubble_outline,
};
