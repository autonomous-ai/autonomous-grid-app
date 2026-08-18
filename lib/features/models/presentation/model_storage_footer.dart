import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/model_storage.dart';
import '../logic/models_providers.dart';

/// The strip under the model list: how much of this computer the models have
/// taken, and the way into the list that gives it back.
///
/// It sits in the sidebar rather than behind a menu because of when people need
/// it — the disk is already full, and "where is that space going?" should be
/// answered by the screen they are already on. Hidden when nothing is
/// downloaded: there is no space to talk about yet.
class ModelStorageFooter extends ConsumerWidget {
  const ModelStorageFooter({
    super.key,
    required this.selected,
    required this.onTap,
  });

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final items = ref.watch(storedItemsProvider);
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(height: 1, color: AppPalette.divider),
        InkWell(
          onTap: onTap,
          child: Container(
            color: selected ? AppSurface.selectedFill : null,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 16,
                  color: selected
                      ? AppPalette.accentOnSurface
                      : AppPalette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${modelSizeLabel(totalStoredBytes(items))} '
                        'on this computer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: AppFont.medium,
                          color: AppPalette.textPrimary,
                          fontFeatures: AppFont.tabularFigures,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        storageCounts(items),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppPalette.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppPalette.textFaint,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
