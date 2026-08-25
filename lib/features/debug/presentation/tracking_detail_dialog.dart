import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../logic/log_format.dart';
import '../logic/tracking_format.dart';

/// The exact JSON one tracked event put on the wire, opened by clicking its row.
///
/// The row shows what the *call site* passed; this shows what actually left the
/// app — context, identity and params merged, in the envelope the server reads.
/// That difference is the whole reason this dialog exists: a field the call site
/// set and the payload doesn't carry is a bug you cannot see from the list.
Future<void> showTrackingDetailDialog(
  BuildContext context,
  AnalyticsLogEntry entry,
) => showDialog<void>(
  context: context,
  builder: (_) => _TrackingDetailDialog(opened: entry),
);

class _TrackingDetailDialog extends ConsumerWidget {
  const _TrackingDetailDialog({required this.opened});

  /// The entry as it stood when the row was clicked — the fallback for
  /// [_current], since the buffer is a ring and Clear empties it outright.
  final AnalyticsLogEntry opened;

  /// This entry as it stands *now*: an event can still be waiting on a retry
  /// when its row is opened, and a panel frozen at the click would keep saying
  /// "Waiting" long after it landed.
  AnalyticsLogEntry _current(List<AnalyticsLogEntry> entries) {
    for (final entry in entries) {
      if (entry.id == opened.id) return entry;
    }
    return opened;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // dialog content — follow theme flips.
    final theme = Theme.of(context);
    final entry = ref.watch(analyticsLogProvider.select(_current));
    final payload = entry.payload;
    final width = math.min(MediaQuery.sizeOf(context).width - 96, 620.0);

    return AlertDialog(
      title: SizedBox(
        width: width,
        child: Row(
          children: [
            Expanded(
              child: Text(entry.name, style: theme.textTheme.titleMedium),
            ),
            if (payload != null) CopyIconButton(value: prettyBody(payload)),
          ],
        ),
      ),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MetaRow(label: 'status', value: trackedStatusLabel(entry.status)),
              MetaRow(label: 'tracked', value: formatLogTime(entry.queuedAt)),
              if (entry.attempts > 0)
                MetaRow(label: 'attempts', value: '${entry.attempts}'),
              if (entry.took case final took?)
                MetaRow(label: 'took', value: formatLogDuration(took)),
              if (entry.note case final note?)
                MetaRow(label: 'outcome', value: note),
              const SizedBox(height: 12),
              _Payload(payload: payload),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The body as it was sent, re-indented — or a plain statement that nothing has
/// been sent yet, which is a state this list shows often (a queued event, an
/// event dropped before it ever reached the wire).
class _Payload extends StatelessWidget {
  const _Payload({required this.payload});

  final String? payload;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final body = payload;
    if (body == null) {
      return Text(
        'Nothing has gone over the wire for this event yet.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppPalette.textSecondary,
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppSurface.hoverFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: SelectableText(
        prettyBody(body),
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: AppFont.mono,
          fontFamilyFallback: AppFont.monoFallback,
        ),
      ),
    );
  }
}
