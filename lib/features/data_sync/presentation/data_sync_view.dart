import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../logic/sync_client.dart';
import '../logic/sync_controller.dart';
import '../logic/sync_state.dart';
import 'sync_backup_tile.dart';
import 'sync_password_dialog.dart';

/// Settings ▸ Sync & Backup: copy this computer's chats to the cloud, and put
/// them on another computer.
///
/// The screen is a list of backups because that is what the feature is. Each one
/// was locked with its own password when it was made, so restoring starts by
/// choosing which backup — not by typing a password and hoping it is the right
/// one.
class DataSyncView extends ConsumerWidget {
  const DataSyncView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final signedIn = ref.watch(syncClientProvider) != null;
    return SectionScaffold(
      title: 'Sync & Backup',
      subtitle:
          'Back up your chats to the cloud and restore them on your other '
          'computers. Everything is locked with a password on this computer '
          'first — Grid never receives it.',
      child: signedIn
          ? const _SyncBody()
          : const EmptyState(
              icon: LucideIcons.cloudOff,
              title: 'Sign in to back up your chats',
              message:
                  'Backups belong to your Grid account, so they follow you to '
                  'any computer you sign in on.',
            ),
    );
  }
}

class _SyncBody extends ConsumerWidget {
  const _SyncBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(syncControllerProvider);
    final versions = ref.watch(syncVersionsProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RunBanner(run: run),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: run is SyncBusy ? null : () => _upload(context, ref),
              icon: const Icon(LucideIcons.cloudUpload, size: 18),
              label: const Text('Back up to cloud'),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your backups',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          switch (versions) {
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              icon: LucideIcons.cloud,
              title: 'No backups yet',
              message:
                  'Back up this computer, then sign in on another one and '
                  'restore it there.',
              compact: true,
            ),
            AsyncData(:final value) => Column(
              children: [
                for (final version in value)
                  SyncBackupTile(
                    version: version,
                    busy: run is SyncBusy,
                    onRestore: () => _restore(context, ref, version),
                    onDelete: () => _delete(context, ref, version),
                  ),
              ],
            ),
            AsyncError(:final error) => ErrorBox(
              message: error is SyncApiError
                  ? error.message
                  : "Couldn't load your backups.",
            ),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ],
      ),
    );
  }

  Future<void> _upload(BuildContext context, WidgetRef ref) async {
    final answer = await showNewBackupPasswordDialog(context);
    if (answer == null) return;
    await ref
        .read(syncControllerProvider.notifier)
        .upload(password: answer.password, hint: answer.hint);
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    SyncVersion version,
  ) async {
    final answer = await showRestorePasswordDialog(context, hint: version.hint);
    if (answer == null) return;
    await ref
        .read(syncControllerProvider.notifier)
        .download(
          version: version,
          password: answer.password,
          // Only asked when the backup would write over chats that are already
          // here; the controller skips it entirely otherwise, so a first restore
          // on a new computer is one dialog, not two.
          confirm: (preview) async =>
              context.mounted &&
              await showRestoreConflictDialog(context, preview) == true,
        );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SyncVersion version,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: appMenuFill(),
        surfaceTintColor: Colors.transparent,
        title: const Text('Delete this backup?'),
        content: Text(
          'Backup ${version.version} from ${version.deviceLabel} will be '
          'removed from the cloud. The chats on this computer are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(syncControllerProvider.notifier)
        .deleteVersion(version.version);
  }
}

/// The one line that says what just happened, or what is happening now.
class _RunBanner extends ConsumerWidget {
  const _RunBanner({required this.run});

  final SyncRunState run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return switch (run) {
      SyncIdle() => const SizedBox.shrink(),
      SyncBusy(:final stage, :final done, :final total) => Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              total > 0
                  ? '${_stageLabel(stage)} (${done + 1} of $total)'
                  : _stageLabel(stage),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      SyncSucceeded(:final message) => _Notice(
        icon: LucideIcons.circleCheck,
        message: message,
        color: theme.colorScheme.primary,
        onDismiss: () =>
            ref.read(syncControllerProvider.notifier).acknowledge(),
      ),
      SyncFailed(:final message) => _Notice(
        icon: LucideIcons.circleAlert,
        message: message,
        color: theme.colorScheme.error,
        onDismiss: () =>
            ref.read(syncControllerProvider.notifier).acknowledge(),
      ),
    };
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.message,
    required this.color,
    required this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color color;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
        IconButton(
          onPressed: onDismiss,
          icon: const Icon(LucideIcons.x, size: 16),
          tooltip: 'Dismiss',
        ),
      ],
    );
  }
}

/// What each stage is called on screen. Plain descriptions of what the computer
/// is doing right now — "Locking your chats", not "Deriving key".
String _stageLabel(SyncStage stage) => switch (stage) {
  SyncStage.gathering => 'Gathering your chats…',
  SyncStage.sealing => 'Locking with your password…',
  SyncStage.uploadingMedia => 'Uploading files',
  SyncStage.uploadingSnapshot => 'Uploading your chats…',
  SyncStage.downloading => 'Downloading the backup…',
  SyncStage.downloadingMedia => 'Downloading files',
  SyncStage.merging => 'Adding them to this computer…',
};
