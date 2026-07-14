import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/session_expiry_controller.dart';

/// App-wide strip shown while the app silently tries `grid sync` to renew an
/// expired session. If that refresh fails the app routes to the login screen
/// (see `RootView`), so this strip only ever needs to cover the transient
/// "Refreshing…" state — anything else is invisible.
class SessionExpiredBanner extends ConsumerWidget {
  const SessionExpiredBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionExpiryProvider);
    if (status != SessionExpiry.refreshing) return const SizedBox.shrink();
    return const _RefreshingRow();
  }
}

/// Quiet, non-alarming strip while the refresh is in flight.
class _RefreshingRow extends StatelessWidget {
  const _RefreshingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Refreshing your Grid session…',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
