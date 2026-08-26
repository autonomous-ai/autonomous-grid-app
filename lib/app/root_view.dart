import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/logic/session_controller.dart';
import '../features/auth/logic/session_expiry_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/network/logic/grid_choice.dart';
import '../features/onboarding/logic/installer_rows.dart';
import '../features/onboarding/logic/onboarding_gate.dart';
import '../features/onboarding/logic/welcome_controller.dart';
import '../features/onboarding/preflight_providers.dart';
import '../features/onboarding/preflight_screen.dart';
import '../features/onboarding/presentation/choice_screen.dart';
import '../features/onboarding/presentation/grid_choice_screen.dart';
import '../features/onboarding/presentation/installer_screen.dart';
import '../features/onboarding/presentation/welcome_screen.dart';
import '../shared/layouts/home_shell.dart';
import '../shared/widgets/app_spinner.dart';

/// Routes between the top-level states: preflight, login (no session), first-run
/// setup (installing the assistant), the choose-a-grid fork, the choose-a-model
/// fork (a grid with nothing to chat with yet), and the app shell.
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

            // Which grid, before anything that reads the answer. The model
            // fork below asks what *the selected grid* serves, so deciding it
            // first would judge a grid the user hadn't chosen yet — and on a
            // second launch this is already answered, so it costs nothing.
            if (ref.watch(gridChoiceNeededProvider)) {
              return const GridChoiceScreen();
            }

            // With the assistant in place, decide where to land: straight into
            // the app when the grid can already chat (or the user has chosen a
            // path before), or the choose-a-model fork when it can't.
            //
            // The welcome screen sits in the `home` arm and nowhere else: it is
            // the last thing before the app, so it must not come between the
            // user and a setup step they still have to finish.
            return switch (ref.watch(onboardingRouteProvider)) {
              OnboardingRoute.resolving => const _Splash(),
              OnboardingRoute.choose => const OnboardingChoiceScreen(),
              OnboardingRoute.home =>
                ref.watch(welcomeSeenProvider)
                    ? const HomeShell()
                    : const WelcomeScreen(),
            };
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
