import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';
import '../logic/session_expiry_controller.dart';

/// Opens [url] in the user's default browser. Returns false if it could not be
/// launched (malformed URL or no handler) so callers can fall back to copy.
Future<bool> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Device-flow login. Triggers `grid login --no-browser`, shows the URL +
/// code while the CLI polls, and flips to the app on success.
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
    // We land here from an expired session (RootView routes needsLogin -> login),
    // so tell the user why they're back at sign-in instead of the app.
    final sessionExpired =
        ref.watch(sessionExpiryProvider) == SessionExpiry.needsLogin;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (state) {
              AuthAwaitingApproval(:final url) => _ApprovalView(
                  url: url,
                  onCancel: controller.cancel,
                ),
              AuthStarting() || AuthSuccess() =>
                const _Busy(label: 'Signing in…'),
              AuthFailure(:final message) => _SignIn(
                  onSignIn: controller.login,
                  error: message,
                  sessionExpired: sessionExpired,
                ),
              AuthIdle() => _SignIn(
                  onSignIn: controller.login,
                  sessionExpired: sessionExpired,
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _SignIn extends StatelessWidget {
  const _SignIn({
    required this.onSignIn,
    this.error,
    this.sessionExpired = false,
  });

  final VoidCallback onSignIn;
  final String? error;

  /// True when the user was routed here because their session expired, so the
  /// subtitle explains the bounce instead of showing the product tagline.
  final bool sessionExpired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Full-bleed square icon (the purple glow reaches every edge), shown raw
        // so the border isn't clipped.
        Image.asset('assets/brand/grid_logo_bg.png',
            width: 72, height: 72, filterQuality: FilterQuality.medium),
        const SizedBox(height: 16),
        Text('Grid', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          sessionExpired
              ? 'Your session expired. Sign in again to continue.'
              : 'One private endpoint for the AI models you run.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onSignIn,
          icon: const Icon(Icons.login),
          label: const Text('Sign in with Google'),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          Text(error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

class _ApprovalView extends StatelessWidget {
  const _ApprovalView({
    required this.url,
    required this.onCancel,
  });

  final String url;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Finish signing in', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'We opened Grid sign-in in your browser. Approve the sign-in there '
          'to continue.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Waiting for approval…'),
          ],
        ),
        const SizedBox(height: 20),
        // Fallbacks, de-emphasized — the browser usually opened already.
        _BrowserFallback(url: url),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}

/// Collapsed "browser didn't open?" helper — the open button + copyable URL.
class _BrowserFallback extends StatelessWidget {
  const _BrowserFallback({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: const Text("Browser didn't open?"),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: () => _openInBrowser(url),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open in browser'),
          ),
        ),
        const SizedBox(height: 8),
        _CopyField(label: 'URL', value: url),
      ],
    );
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy',
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ),
      child: Text(value, overflow: TextOverflow.ellipsis),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label),
      ],
    );
  }
}
