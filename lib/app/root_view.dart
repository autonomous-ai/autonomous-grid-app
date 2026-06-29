import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/logic/session_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/onboarding/preflight_providers.dart';
import '../features/onboarding/preflight_screen.dart';
import '../shared/layouts/home_shell.dart';

/// Routes between the three top-level states: onboarding (no `grid`),
/// login (no session), and the app shell.
class RootView extends ConsumerWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(preflightProvider).when(
          loading: () => const _Splash(),
          error: (error, _) => _ErrorView(
            message: '$error',
            onRetry: () => ref.invalidate(preflightProvider),
          ),
          data: (report) {
            if (!report.canProceed) return PreflightScreen(report: report);
            final loggedIn = ref.watch(sessionProvider).isLoggedIn;
            return loggedIn ? const HomeShell() : const LoginScreen();
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
              child: Image.asset('assets/tray/tray_icon.png',
                  width: 64, height: 64),
            ),
            const SizedBox(height: 20),
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 16),
            Text('Starting Grid…',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
              Icon(Icons.error_outline,
                  size: 48, color: theme.colorScheme.error),
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
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
