import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../../shared/widgets/glass_card.dart';

/// Where the events go, whether they are going at all, and the two ids they are
/// filed under.
///
/// First on the Tracking screen because it is the first thing to check when the
/// list is empty: a muted stream and a quiet app look identical from the list
/// alone. When it is off, the reason says so in a sentence — "no events" with
/// nothing beside it is the state a developer wastes an hour on.
class TrackingStreamCard extends ConsumerWidget {
  const TrackingStreamCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    final theme = Theme.of(context);
    final status = ref.watch(analyticsStatusProvider);

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.podcasts_rounded,
                size: 16,
                color: AppPalette.textFaint,
              ),
              const SizedBox(width: 8),
              Text('analytics stream', style: theme.textTheme.titleSmall),
              const Spacer(),
              BadgePill(
                label: status.enabled ? 'Reporting' : 'Off',
                color: status.enabled
                    ? AppPalette.online
                    : AppPalette.textSecondary,
                compact: true,
              ),
            ],
          ),
          if (status.offReason case final reason?) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 2),
          AddressRow(label: 'endpoint', value: '${status.endpoint}'),
          AddressRow(label: 'device id', value: status.deviceId),
          MetaRow(
            label: 'visit id',
            value: status.sessionId.isEmpty
                ? 'starts with the first event'
                : status.sessionId,
          ),
        ],
      ),
    );
  }
}
