import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';

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

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (state) {
              AuthAwaitingApproval(:final url, :final userCode) =>
                _ApprovalView(url: url, userCode: userCode),
              AuthStarting() || AuthSuccess() =>
                const _Busy(label: 'Signing in…'),
              AuthFailure(:final message) =>
                _SignIn(onSignIn: controller.login, error: message),
              AuthIdle() => _SignIn(onSignIn: controller.login),
            },
          ),
        ),
      ),
    );
  }
}

class _SignIn extends StatelessWidget {
  const _SignIn({required this.onSignIn, this.error});

  final VoidCallback onSignIn;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hub_outlined, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('Grid', style: theme.textTheme.headlineMedium),
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
  const _ApprovalView({required this.url, required this.userCode});

  final String url;
  final String userCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Finish signing in', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          "We've opened your browser — confirm the code below. "
          "If it didn't open, use the button or copy the URL.",
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => _openInBrowser(url),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open in browser'),
        ),
        const SizedBox(height: 16),
        _CopyField(label: 'URL', value: url),
        const SizedBox(height: 8),
        _CopyField(label: 'Code', value: userCode, monospace: true),
        const SizedBox(height: 24),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Waiting for approval…'),
          ],
        ),
      ],
    );
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

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
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: monospace ? const TextStyle(fontFamily: 'monospace') : null,
      ),
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
