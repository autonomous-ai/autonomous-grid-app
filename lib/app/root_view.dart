import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/logic/session_controller.dart';
import '../features/auth/logic/session_expiry_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/network/logic/grid_choice.dart';
import '../features/onboarding/logic/installer_rows.dart';
import '../features/onboarding/preflight_providers.dart';
import '../features/onboarding/preflight_screen.dart';
import '../features/onboarding/presentation/grid_choice_screen.dart';
import '../features/onboarding/presentation/installer_screen.dart';
import '../shared/layouts/home_shell.dart';
import '../shared/widgets/app_spinner.dart';

/// Routes between the top-level states: preflight, the front door (no session),
/// first-run setup (installing the assistant), the choose-a-grid fork, and the
/// app shell.
///
/// Three screens stand between a new install and chat, and the order is the
/// point: make the case, ask which grid, then get out of the way. What a model
/// is and where it runs is not a question to put in front of someone who has not
/// seen the product yet — chat asks it, once, at the moment it matters, through
/// [NoModelYet].
class RootView extends ConsumerWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(preflightProvider)
        .when(
          loading: () => const _Splash(),
          error: (error, _) => _ErrorView(
            message: '$error',
            onRetry: () => ref.invalidate(preflightProvider),
          ),
          data: (report) {
            final issue = report.issue;
            if (issue != null) return PreflightScreen(issue: issue);
            final loggedIn = ref.watch(sessionProvider).isLoggedIn;
            // A dead session token still sits in `credentials.toml`, so
            // `isLoggedIn` stays true even after it expires. Treat "couldn't
            // refresh" as signed-out and route straight to login instead of
            // stranding the user in the app behind a banner.
            final needsLogin =
                ref.watch(sessionExpiryProvider) == SessionExpiry.needsLogin;
            if (!loggedIn || needsLogin) return const LoginScreen();

            // A brand-new computer has no assistant yet. Set it up in front of
            // the user, as its own screen, before anything else.
            if (ref.watch(showInstallerProvider)) {
              return const InstallerScreen();
            }

            // Which grid, before the app that reads the answer — everything
            // past here is scoped to the selected grid, and on a second launch
            // this is already answered, so it costs nothing.
            if (ref.watch(gridChoiceNeededProvider)) {
              return const GridChoiceScreen();
            }

            // Nothing left to ask. A grid with no model reaching chat is not a
            // reason to hold someone here: chat's own empty state says so and
            // hands them the way to fix it, which is the same door they'd use
            // the second time anyway.
            return const HomeShell();
          },
        );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                'assets/tray/tray_icon.png',
                width: 64,
                height: 64,
              ),
            ),
            const SizedBox(height: 20),
            const AppSpinner(size: SpinnerSize.large),
            const SizedBox(height: 16),
            Text(
              'Starting Grid…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when preflight itself throws (not the normal "grid missing" path) —
/// a friendly headline with the technical detail secondary, and a retry.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text("Grid couldn't start", style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Something went wrong while starting up. Try again — if it keeps '
                'happening, restart the app.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
