import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';
import 'widgets/approval_view.dart';
import 'widgets/sign_in_view.dart';
import 'widgets/theme_toggle.dart';

/// Opens [url] in the user's default browser. Returns false if it could not be
/// launched (malformed URL or no handler) so callers can fall back to copy.
Future<bool> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Device-flow login. Triggers `grid login --no-browser`, shows the URL + code
/// while the CLI polls, and flips to the app on success.
///
/// Both of its pages wear the same frame as first-run setup and the
/// choose-a-model fork ([OnboardingPage]): the three screens are the first two
/// minutes of the product, and they used to be three different designs.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Auto-open the browser the moment the device-flow URL streams in, so the
    // user doesn't have to copy/paste it. Fires once per transition; the copy
    // fields and the "Open in browser" button below stay as fallbacks.
    ref.listen<AuthState>(authControllerProvider, (prev, next) {
      if (next is AuthAwaitingApproval && prev is! AuthAwaitingApproval) {
        _openInBrowser(next.url);
      }
    });

    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    // Light / Dark / System, reachable before signing in — it writes the same
    // persisted themeModeProvider the account menu does, so the pick sticks.
    const corner = ThemeToggle();

    return switch (state) {
      AuthAwaitingApproval(:final url, :final userCode) => ApprovalView(
        url: url,
        userCode: userCode,
        onCancel: controller.cancel,
        corner: corner,
      ),
      // A flash between the two pages — same ground as both, so the window
      // doesn't change colour on the way through.
      AuthStarting() || AuthSuccess() => Scaffold(
        backgroundColor: AppPalette.windowBg,
        body: const LoadingView(message: 'Signing in…'),
      ),
      AuthFailure(:final message) => SignInView(
        onSignIn: controller.login,
        error: message,
        corner: corner,
      ),
      AuthIdle() => SignInView(onSignIn: controller.login, corner: corner),
    };
  }
}
