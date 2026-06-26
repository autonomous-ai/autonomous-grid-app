import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/widgets/error_box.dart';
import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';

/// Opens [url] in the user's default browser. Tries `url_launcher` first, then
/// falls back to the OS opener — the frozen `grid` CLI can't reliably open a
/// browser when spawned from the app, so opening it is the app's job. Returns
/// false only when both routes fail, so callers can prompt a manual copy.
Future<bool> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return true;
  } catch (_) {
    // url_launcher can throw on desktop when no handler is wired up — fall back.
  }
  return _openWithOsOpener(url);
}

/// Last-resort browser open via the platform's URL opener. The app already
/// shells out to `grid`, so this path works even where `url_launcher` doesn't.
Future<bool> _openWithOsOpener(String url) async {
  final String exe;
  final List<String> args;
  if (Platform.isMacOS) {
    (exe, args) = ('open', [url]);
  } else if (Platform.isLinux) {
    (exe, args) = ('xdg-open', [url]);
  } else if (Platform.isWindows) {
    (exe, args) = ('cmd', ['/c', 'start', '', url]);
  } else {
    return false;
  }
  try {
    final result = await Process.run(exe, args);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Device-flow login. Triggers `grid auth login --no-browser`, shows the URL +
/// code while the CLI polls, and flips to the app on success.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Auto-open the browser the moment the device-flow URL streams in. If it
    // can't be opened (sandbox, no handler), tell the user to use the link
    // shown below instead of leaving them on a silent spinner.
    ref.listen<AuthState>(authControllerProvider, (prev, next) async {
      if (next is! AuthAwaitingApproval || prev is AuthAwaitingApproval) return;
      final opened = await _openInBrowser(next.url);
      if (opened || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            "Couldn't open the browser automatically — use the link below."),
      ));
    });

    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                switch (state) {
                  AuthAwaitingApproval(:final url, :final userCode) =>
                    _ApprovalView(
                        url: url,
                        userCode: userCode,
                        onCancel: controller.cancel),
                  AuthStarting() =>
                    _Busy(label: 'Signing in…', onCancel: controller.cancel),
                  AuthSuccess() => const _Busy(label: 'Signing in…'),
                  AuthFailure(:final message) =>
                    _SignIn(onSignIn: controller.login, error: message),
                  AuthIdle() => _SignIn(onSignIn: controller.login),
                },
                const _CliConsole(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live `grid auth login` output — the streamed device-login URL, code and any
/// errors — so a stuck or browser-less sign-in stays visible and copy-able.
class _CliConsole extends ConsumerWidget {
  const _CliConsole();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(authLogProvider);
    if (lines.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          reverse: true,
          child: SelectableText(
            lines.join('\n'),
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 12, height: 1.4),
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
          ErrorBox(message: error!),
        ],
      ],
    );
  }
}

class _ApprovalView extends StatelessWidget {
  const _ApprovalView({
    required this.url,
    required this.userCode,
    required this.onCancel,
  });

  final String url;
  final String userCode;
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
        const SizedBox(height: 12),
        TextButton(onPressed: onCancel, child: const Text('Cancel')),
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
  const _Busy({required this.label, this.onCancel});
  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label),
        if (onCancel != null) ...[
          const SizedBox(height: 16),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ],
    );
  }
}
