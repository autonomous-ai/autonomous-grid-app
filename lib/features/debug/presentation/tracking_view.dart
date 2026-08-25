import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/section_scaffold.dart';
import 'debug_filter_bar.dart';
import 'debug_toolbar_button.dart';
import 'tracking_stream_card.dart';
import 'tracking_tile.dart';

/// The lens the list is filtered to. Waiting and Failed are separate: an event
/// still queued is the network's problem, a refused one is ours.
enum _EventFilter { all, sent, waiting, failed }

extension on _EventFilter {
  String get label => switch (this) {
    _EventFilter.all => 'All',
    _EventFilter.sent => 'Sent',
    _EventFilter.waiting => 'Waiting',
    _EventFilter.failed => 'Failed',
  };

  bool matches(AnalyticsLogEntry entry) => switch (this) {
    _EventFilter.all => true,
    _EventFilter.sent => entry.status == AnalyticsEventStatus.sent,
    _EventFilter.waiting => entry.status == AnalyticsEventStatus.queued,
    _EventFilter.failed =>
      entry.status == AnalyticsEventStatus.refused ||
          entry.status == AnalyticsEventStatus.dropped,
  };
}

/// Tracking tab — every analytics event this app reports, newest first, with
/// the exact JSON behind each one.
///
/// The Debug tab beside it answers "what did the app ask the grid for". This
/// answers the question analytics always raises and normally cannot: *did that
/// event actually leave, and what was in it?* Without it, an event that was
/// never sent, sent with a missing field, or refused by the server looks
/// exactly like an event that landed — the app is silent either way, by design.
class TrackingView extends ConsumerStatefulWidget {
  const TrackingView({super.key});

  @override
  ConsumerState<TrackingView> createState() => _TrackingViewState();
}

class _TrackingViewState extends ConsumerState<TrackingView> {
  _EventFilter _filter = _EventFilter.all;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(analyticsLogProvider);
    final visible = [
      for (final entry in entries)
        if (_filter.matches(entry)) entry,
    ];

    return SectionScaffold(
      title: 'Tracking',
      subtitle: 'Every analytics event this app reports, and where it goes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TrackingStreamCard(),
          const SizedBox(height: 16),
          _Toolbar(total: entries.length),
          const SizedBox(height: 12),
          DebugFilterBar(
            lenses: [
              for (final f in _EventFilter.values)
                FilterLens(
                  label: f.label,
                  count: entries.where(f.matches).length,
                  selected: f == _filter,
                  onTap: () => setState(() => _filter = f),
                  danger: f == _EventFilter.failed,
                  hideWhenEmpty: f == _EventFilter.failed,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _list(entries.isEmpty, visible)),
        ],
      ),
    );
  }

  Widget _list(bool nothingTracked, List<AnalyticsLogEntry> visible) {
    if (visible.isNotEmpty) {
      return ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) => TrackingTile(entry: visible[i]),
      );
    }
    // Nothing tracked yet vs the filter hid everything — two different stories.
    if (nothingTracked) {
      return const EmptyState(
        icon: Icons.query_stats_rounded,
        title: 'No events yet',
        message:
            'Move around the app — opening a screen or signing in reports an '
            'event, and each one will show up here with what it sent.',
      );
    }
    return const EmptyState.noMatches(message: 'No event matches this filter.');
  }
}

/// The event count and Clear. The count is everything captured this session,
/// not the filtered view — it's the buffer's fill level.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.total});

  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '$total event${total == 1 ? '' : 's'}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const Spacer(),
        DebugToolbarButton(
          icon: Icons.delete_outline_rounded,
          label: 'Clear',
          onPressed: total == 0
              ? null
              : () => ref.read(analyticsLogProvider.notifier).clear(),
        ),
      ],
    );
  }
}
