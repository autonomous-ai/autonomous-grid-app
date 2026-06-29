import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/auth/logic/session_expiry_controller.dart';

/// App-wide strip for session recovery. While the app tries `grid sync` it shows
/// a quiet "Refreshing…" row; only if that fails does it prompt a re-login.
/// Invisible when the session is healthy or already signed out.
class SessionExpiredBanner extends ConsumerWidget {
  const SessionExpiredBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionExpiryProvider);
    final loggedIn = ref.watch(sessionProvider).isLoggedIn;
    if (status == SessionExpiry.healthy || !loggedIn) {
      return const SizedBox.shrink();
    }
    return switch (status) {
      SessionExpiry.refreshing => const _RefreshingRow(),
      SessionExpiry.needsLogin => const _NeedsLoginRow(),
      SessionExpiry.healthy => const SizedBox.shrink(),
    };
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
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Refreshing your Grid session…',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// Refresh failed — the user has to sign in again.
class _NeedsLoginRow extends ConsumerWidget {
  const _NeedsLoginRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.lock_clock_outlined,
                size: 16, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Your Grid session expired and couldn't be refreshed. "
                'Sign in again to continue.',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => _reLogin(ref),
              child: const Text('Sign in again'),
            ),
          ],
        ),
      ),
    );
  }

  /// Reset the flag, then sign out — the app routes to the login screen where
  /// the device flow gets a fresh session.
  void _reLogin(WidgetRef ref) {
    ref.read(sessionExpiryProvider.notifier).reset();
    ref.read(authControllerProvider.notifier).logout();
  }
}
