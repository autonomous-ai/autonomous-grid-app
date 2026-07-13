import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_environment.dart';
import '../logic/app_updater_service.dart';

/// Toasts the outcome of every update check, wherever it was started from — the
/// macOS "Grid ▸ Check for Updates…" app menu or the in-app account menu.
///
/// It wraps the whole app rather than living in the title bar because the app
/// menu is reachable on the login screen too, where the title bar isn't built:
/// without a listener mounted there, a tap on the menu item resolved to silence.
class UpdateToastScope extends ConsumerWidget {
  const UpdateToastScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(appUpdateStatusProvider, (_, next) {
      final status = next.asData?.value;
      if (status != null) showUpdateToast(context, status);
    });
    return child;
  }
}

/// Shows one update-check outcome as a snack bar. The in-flight "Checking…"
/// toast is replaced by its outcome instead of queueing behind it, so the
/// result isn't delayed by seconds.
void showUpdateToast(BuildContext context, UpdateStatus status) {
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  final message = switch (status) {
    UpdateChecking() => 'Checking for updates…',
    UpdateUpToDate() => "You're on the latest version.",
    UpdateAvailable(:final version) =>
      version == null
          ? 'An update is available — follow the prompt to install.'
          : 'Update available: $version — follow the prompt to install.',
    UpdateFailed(:final message) => "Couldn't check for updates: $message",
    UpdateUnsupported() =>
      "This copy of Grid can't update itself — download the latest version "
          'from the website.',
  };
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
      action: status is UpdateUnsupported
          ? SnackBarAction(
              label: 'Download',
              onPressed: () => launchUrl(
                Uri.parse(AppEnvironment.websiteUrl),
                mode: LaunchMode.externalApplication,
              ),
            )
          : null,
    ),
  );
}
