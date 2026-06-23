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
          error: (error, _) => _ErrorView(message: '$error'),
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
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(message)));
}
