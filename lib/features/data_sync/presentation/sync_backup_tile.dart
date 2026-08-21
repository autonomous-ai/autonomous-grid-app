import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../core/age_label.dart';
import '../logic/sync_client.dart';

/// One backup in the list: when it was made, from which computer, and what's in
/// it — enough to choose between two backups before typing either password.
class SyncBackupTile extends StatelessWidget {
  const SyncBackupTile({
    super.key,
    required this.version,
    required this.busy,
    required this.onRestore,
    required this.onDelete,
  });

  final SyncVersion version;

  /// A transfer is running; both actions are held so a second one can't start
  /// on top of it.
  final bool busy;

  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppGlass.hair),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.cloud, size: 18, color: AppPalette.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  version.deviceLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _summary(version),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: busy ? null : onRestore,
            child: const Text('Restore'),
          ),
          IconButton(
            onPressed: busy ? null : onDelete,
            icon: const Icon(LucideIcons.trash2, size: 16),
            tooltip: 'Delete this backup',
          ),
        ],
      ),
    );
  }
}

/// "42 chats · 12 files · 2d ago · 1.2 MB" — the age reuses the sidebar's own
/// short form so one idea is spelled one way across the app.
String _summary(SyncVersion version) {
  final chats = version.chatCount;
  final media = version.counts['media'] ?? 0;
  return [
    '$chats ${chats == 1 ? 'chat' : 'chats'}',
    if (media > 0) '$media ${media == 1 ? 'file' : 'files'}',
    '${ageLabel(version.createdAt, DateTime.now())} ago',
    _size(version.sizeBytes),
  ].join(' · ');
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
