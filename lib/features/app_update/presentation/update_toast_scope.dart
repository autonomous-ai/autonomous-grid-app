import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_environment.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/app_updater_service.dart';

/// Toasts the outcome of every update check, wherever it was started from — the
/// macOS "Grid ▸ Check for Updates…" app menu or the in-app account menu.
///
/// It wraps the whole app rather than living in the title bar because the app
/// menu is reachable on the login screen too, where the title bar isn't built:
/// without a listener mounted there, a tap on the menu item resolved to silence.
///
/// This used to own a bespoke overlay toast — the shell of which became
/// [ToastScope]. All that's left here is the update-specific part: turning an
/// [UpdateStatus] into a [ToastSpec].
class UpdateToastScope extends ConsumerWidget {
  const UpdateToastScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(appUpdateStatusProvider, (_, next) {
      final status = next.asData?.value;
      if (status != null) ToastScope.show(context, _spec(status));
    });
    return child;
  }

  ToastSpec _spec(UpdateStatus status) => switch (status) {
    UpdateChecking() => const ToastSpec(
      message: 'Checking for updates...',
      icon: Icons.sync_rounded,
    ),
    UpdateUpToDate() => const ToastSpec(
      message: "You're on the latest version.",
      severity: ToastSeverity.success,
    ),
    UpdateAvailable(:final version) => ToastSpec(
      message: version == null
          ? 'An update is available. Follow the prompt to install.'
          : 'Update available: $version. Follow the prompt to install.',
      icon: Icons.system_update_alt_rounded,
    ),
    UpdateFailed(:final message) => ToastSpec(
      message: "Couldn't check for updates: $message",
      severity: ToastSeverity.error,
    ),
    UpdateUnsupported() => ToastSpec(
      message: "This copy of Grid can't update itself.",
      severity: ToastSeverity.warning,
      icon: Icons.open_in_new_rounded,
      action: ToastAction(
        label: 'Download',
        onPressed: () => launchUrl(
          Uri.parse(AppEnvironment.websiteUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
    ),
  };
}
