import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_storage.dart';
import 'model_delete_confirm.dart';

/// One thing on disk: what it is, what it costs, and the way to get that space
/// back.
///
/// The delete is a button rather than a swipe or a menu because of what this
/// list is for — a full disk — and it goes off, with the reason in its tooltip,
/// whenever removing the files would break something that is running.
class StoredModelRow extends ConsumerWidget {
  const StoredModelRow({
    super.key,
    required this.item,
    required this.inUse,
    required this.downloadRunning,
    required this.deleting,
  });

  final StoredItem item;

  /// The engine is serving this model right now — deleting it would yank the
  /// weights out from under a live model, so the button is off and the row says
  /// where to stop it.
  final bool inUse;

  /// A download is in flight somewhere in the app. Only blocks the unfinished
  /// rows: those are the `.part` files a live download could be writing.
  final bool downloadRunning;

  final bool deleting;

  bool get _blocked => inUse || (item.isUnfinished && downloadRunning);

  String? get _blockedReason {
    if (inUse) {
      return 'This model is running right now. Stop it in Share '
          'Intelligence to '
          'delete it.';
    }
    if (item.isUnfinished && downloadRunning) {
      return 'A download is running. Wait for it to finish, or cancel it, '
          'before deleting this.';
    }
    return null;
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmModelDelete(
      context,
      label: item.label,
      sizeBytes: item.sizeBytes,
      unfinished: item.isUnfinished,
    );
    if (!confirmed) return;
    await ref
        .read(modelDeleteControllerProvider.notifier)
        .delete(item.files, label: item.label);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);

    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Icon(
            item.isUnfinished ? Icons.pause_circle_outline : Icons.dns_outlined,
            size: 18,
            color: item.isUnfinished ? AppPalette.warn : AppPalette.textFaint,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppFont.medium,
                  ),
                ),
                if (item.detail case final detail?) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (inUse) ...[
            BadgePill(label: 'In use', color: AppPalette.online, compact: true),
            const SizedBox(width: 10),
          ],
          Text(
            modelSizeLabel(item.sizeBytes),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: AppFont.medium,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Center(
              child: deleting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : AppIconButton(
                      icon: Icons.delete_outline,
                      destructive: true,
                      size: 16,
                      tooltip: _blockedReason ?? 'Delete',
                      onPressed: _blocked ? null : () => _delete(context, ref),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
