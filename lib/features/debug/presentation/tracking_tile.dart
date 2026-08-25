import 'package:flutter/material.dart';

import '../../../infrastructure/analytics/analytics_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/log_format.dart';
import '../logic/tracking_format.dart';
import 'tracking_detail_dialog.dart';

/// One tracked event in the Tracking list: what was tracked, how it ended, and
/// — on a click — the exact JSON it put on the wire.
///
/// Plain text rather than selectable, like [LogTile] and for the same reason: a
/// `SelectableText` eats the tap that opens the row, and what it would let you
/// copy is the summary, not the payload.
class TrackingTile extends StatefulWidget {
  const TrackingTile({super.key, required this.entry});

  final AnalyticsLogEntry entry;

  @override
  State<TrackingTile> createState() => _TrackingTileState();
}

class _TrackingTileState extends State<TrackingTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // list item — must self-watch to follow flips.
    final theme = Theme.of(context);
    final entry = widget.entry;
    final summary = trackedSummaryLine(entry);

    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => showTrackingDetailDialog(context, entry),
          child: GlassCard(
            style: GlassCardStyle.inset,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TrackingStatusIcon(status: entry.status),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: AppFont.mono,
                          fontFamilyFallback: AppFont.monoFallback,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                    ),
                    // Only when it means something: one attempt is the normal
                    // case, and a badge that is always there stops being read.
                    if (entry.attempts > 1) ...[
                      BadgePill(
                        label: '${entry.attempts} tries',
                        color: AppPalette.textSecondary,
                        compact: true,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _Meta(entry: entry),
                    // Held open whether or not the cursor is here, so a row
                    // doesn't reflow the instant it is pointed at.
                    SizedBox(
                      width: 22,
                      child: _hovered
                          ? Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: AppPalette.textSecondary,
                            )
                          : null,
                    ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 26, right: 22),
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: entry.note == null
                            ? AppPalette.textSecondary
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Waiting / sent / refused / dropped, as one glyph. Shared with the filter bar
/// so a row and the lens that selected it can never disagree.
class TrackingStatusIcon extends StatelessWidget {
  const TrackingStatusIcon({super.key, required this.status, this.size = 16});

  final AnalyticsEventStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    return Icon(_glyph, size: size, color: color(context));
  }

  IconData get _glyph => switch (status) {
    AnalyticsEventStatus.queued => Icons.schedule_rounded,
    AnalyticsEventStatus.sent => Icons.check_circle,
    AnalyticsEventStatus.refused => Icons.error,
    AnalyticsEventStatus.dropped => Icons.remove_circle_outline_rounded,
  };

  /// The status colour, exposed so a pill or a label can be tinted to match.
  Color color(BuildContext context) => switch (status) {
    AnalyticsEventStatus.queued => AppPalette.textFaint,
    AnalyticsEventStatus.sent => AppPalette.online,
    AnalyticsEventStatus.refused => Theme.of(context).colorScheme.error,
    AnalyticsEventStatus.dropped => Theme.of(context).colorScheme.error,
  };
}

/// The clock time and, once it has settled, how long it took — the trailing
/// column of a row.
class _Meta extends StatelessWidget {
  const _Meta({required this.entry});

  final AnalyticsLogEntry entry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final took = entry.took;
    return Text(
      [
        formatLogTime(entry.queuedAt),
        if (took != null) formatLogDuration(took),
      ].join(' · '),
      style: TextStyle(
        fontSize: 11.5,
        color: AppPalette.textFaint,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
