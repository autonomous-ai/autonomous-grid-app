import 'package:flutter/material.dart';

import '../../../../shared/layouts/onboarding_page.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/soft_action_button.dart';
import '../google_logo.dart';

/// The sign-in page: the brand mark, what Grid is in one line, and the one thing
/// to do.
///
/// Nothing about *why* the user is here. Arriving from an expired session and
/// opening the app cold look the same from this screen, and both end in the same
/// tap — an explanation of the bounce is a line about the past in front of the
/// one thing to do next.
class SignInView extends StatelessWidget {
  const SignInView({
    super.key,
    required this.onSignIn,
    this.error,
    this.corner,
  });

  final VoidCallback onSignIn;
  final String? error;
  final Widget? corner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OnboardingPage(
      title: 'Sign in to Grid',
      subtitle: 'One private endpoint for the AI models you run.',
      corner: corner,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SoftActionButton(
            leading: const GoogleLogo(size: 18),
            label: 'Sign in with Google',
            onPressed: onSignIn,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 14),
          Text(
            error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 22),
        const _SecureNote(),
      ],
    );
  }
}

/// A quiet "your sign-in is secure" note under the button. It reassures without
/// competing with the one thing on the screen.
class _SecureNote extends StatelessWidget {
  const _SecureNote();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 13,
          color: AppPalette.textSecondary,
        ),
        const SizedBox(width: 6),
        Text(
          'Secure sign-in',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppPalette.textSecondary,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}
