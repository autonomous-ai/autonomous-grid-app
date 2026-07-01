import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../logic/app_update_controller.dart';
import '../logic/app_update_state.dart';

/// App-wide strip that surfaces an available app update from any tab: a call to
/// update, a live download bar, an "installer ready" prompt, or a retry on
/// failure. Hidden while idle, checking, or when a background check fails — a
/// routine check should never nag the user with an error.
class AppUpdateBanner extends ConsumerWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateControllerProvider);
    return switch (state) {
      AppUpdateAvailable s => _AvailableBanner(state: s),
      AppUpdateDownloading s => _DownloadingBanner(state: s),
      AppUpdateInstalling s => _InstallingBanner(state: s),
      AppUpdateFailed s when s.phase != AppUpdatePhase.check =>
        _FailedBanner(state: s),
      _ => const SizedBox.shrink(),
    };
  }
}

/// A newer build exists. Offers "Update now" when there's a downloadable asset,
/// and "Later" unless the update is mandatory.
class _AvailableBanner extends ConsumerWidget {
  const _AvailableBanner({required this.state});
  final AppUpdateAvailable state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appUpdateControllerProvider.notifier);
    final notes = state.info.notes;
    return _BannerFrame(
      icon: Icons.system_update_alt,
      title: 'Grid ${state.info.version} is available'
          '${notes == null ? '' : ' · $notes'}',
      actions: [
        if (state.release != null)
          FilledButton(
            onPressed: controller.downloadAndInstall,
            child: const Text('Update now'),
          ),
        if (!state.mandatory)
          TextButton(onPressed: controller.dismiss, child: const Text('Later')),
      ],
    );
  }
}

/// The installer is downloading — a headline with MB progress plus a thin bar.
class _DownloadingBanner extends ConsumerWidget {
  const _DownloadingBanner({required this.state});
  final AppUpdateDownloading state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(appUpdateControllerProvider.notifier);
    final progress = state.progress;
    final value = progress == null || progress.isIndeterminate
        ? null
        : progress.pct! / 100;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Downloading Grid ${state.info.version}…${_suffix(progress)}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!state.mandatory)
                  TextButton(
                    onPressed: controller.cancelDownload,
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ),
          LinearProgressIndicator(value: value, minHeight: 2),
        ],
      ),
    );
  }

  String _suffix(DownloadProgress? progress) {
    if (progress == null || progress.totalMb == null) return '';
    final pct =
        progress.pct == null ? '' : ' (${progress.pct!.toStringAsFixed(0)}%)';
    return ' ${progress.doneMb.toStringAsFixed(0)}/'
        '${progress.totalMb!.toStringAsFixed(0)} MB$pct';
  }
}

/// The installer opened. Grid must quit so the new build can replace it — the
/// button routes through the normal close path, which stops any running engine
/// first (see WindowLifecycleScope).
class _InstallingBanner extends StatelessWidget {
  const _InstallingBanner({required this.state});
  final AppUpdateInstalling state;

  @override
  Widget build(BuildContext context) {
    return _BannerFrame(
      icon: Icons.check_circle_outline,
      title: 'Installer opened for Grid ${state.info.version}. '
          'Quit Grid to finish updating.',
      actions: [
        FilledButton(
          onPressed: windowManager.close,
          child: const Text('Quit & install'),
        ),
      ],
    );
  }
}

/// A download/install step failed — friendly message with a retry and dismiss.
class _FailedBanner extends ConsumerWidget {
  const _FailedBanner({required this.state});
  final AppUpdateFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(appUpdateControllerProvider.notifier);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 16, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.message,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            if (state.available != null)
              TextButton(
                onPressed: controller.downloadAndInstall,
                child: const Text('Try again'),
              ),
            TextButton(
                onPressed: controller.dismiss, child: const Text('Dismiss')),
          ],
        ),
      ),
    );
  }
}

/// Shared calm strip used by the "available" and "installer ready" states — an
/// icon, a headline, and trailing actions on a surface tint.
class _BannerFrame extends StatelessWidget {
  const _BannerFrame({
    required this.icon,
    required this.title,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}
