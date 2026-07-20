import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../../shared/widgets/toast.dart';
import '../../plugins/presentation/widgets/extension_tile_surface.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_group.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';

/// One model on the shelf — suggested, downloaded, or both.
///
/// Replaces the old `_CatalogTile` + `_ModelTile` pair, which rendered the same
/// file as two rows in two sections. Everything about a model now lives on one
/// row: what it targets, what it costs on disk, and the one action available.
///
/// Built on [ExtensionTileSurface] rather than a `GlassCard` + `Divider` stack,
/// so the list matches the Plugins and Skills tabs: separated by air and a
/// hover lift, never by a rule.
class ShelfModelTile extends ConsumerWidget {
  const ShelfModelTile({super.key, required this.model});

  final ShelfModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette/AppCard tokens.
    final group = model.group;
    final serving = ref.watch(servingModelProvider);
    final inUse =
        group != null &&
        group.fileNames.any((name) => isModelInUse(name, serving));

    return ExtensionTileSurface(
      // Sits on a dialog, not a page — see ExtensionTileSurface.onDialog.
      onDialog: true,
      child: Row(
        children: [
          ExtensionIconBadge(
            // A downloaded model reads as the "on" state of this list — the
            // tinted well is what you scan for to find what's actually here.
            icon: model.isDownloaded
                ? Icons.memory_outlined
                : Icons.cloud_download_outlined,
            active: model.isDownloaded,
          ),
          const SizedBox(width: 12),
          Expanded(child: _Lines(model: model, inUse: inUse)),
          const SizedBox(width: 12),
          _Action(model: model, inUse: inUse),
        ],
      ),
    );
  }
}

/// The name, and one quiet line of facts under it.
class _Lines extends StatelessWidget {
  const _Lines({required this.model, required this.inUse});

  final ShelfModel model;
  final bool inUse;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
            if (inUse) ...[
              const SizedBox(width: 8),
              _RunningTag(),
            ],
          ],
        ),
        const SizedBox(height: 4),
        _MetaLine(model: model),
      ],
    );
  }
}

/// Device target, memory hint and size — merged into one line rather than a chip
/// row over a separate size column, so a row is two lines tall whatever it is.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.model});

  final ShelfModel model;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final parts = <String>[];
    final catalog = model.catalog;
    if (catalog?.target != null) parts.add(catalog!.target!);
    if (catalog != null) {
      parts.add('${catalog.minVramGb.toStringAsFixed(0)} GB+ memory');
    }
    final group = model.group;
    if (group != null) {
      parts.add('${group.sizeGb.toStringAsFixed(2)} GB on disk');
      if (group.isSplit) parts.add(_partsLabel(group));
    }
    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        height: 1.28,
        // An incomplete split set can't be served, so its line carries the
        // warning rather than reading as ordinary metadata.
        color: model.isComplete ? AppPalette.textSecondary : AppPalette.warn,
      ),
    );
  }

  static String _partsLabel(ModelGroup group) {
    final expected = group.expectedParts;
    if (expected != null && group.partCount < expected) {
      return '${group.partCount} of $expected parts — incomplete';
    }
    return '${group.partCount} parts';
  }
}

/// "Running" — the engine is serving this model right now.
class _RunningTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: AppPalette.online, size: 6),
        const SizedBox(width: 5),
        Text(
          'Running',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppPalette.online,
          ),
        ),
      ],
    );
  }
}

/// The one thing you can do with this row: download it, or delete it.
///
/// A model being served has neither — its files can't be pulled out from under a
/// live engine, and it's already here. It gets the tooltip explaining why.
class _Action extends ConsumerWidget {
  const _Action({required this.model, required this.inUse});

  final ShelfModel model;
  final bool inUse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final group = model.group;
    final deleteState = ref.watch(modelDeleteControllerProvider);
    final deleting =
        group != null &&
        deleteState is ModelDeleting &&
        deleteState.label == group.displayName;

    if (deleting) {
      return const SizedBox(width: 32, child: Center(child: AppSpinner()));
    }

    if (inUse) {
      return Tooltip(
        message: 'In use by the running engine — stop it to delete this model.',
        // textSecondary, not textFaint: faint measures 2.56:1 on the light row,
        // under WCAG 1.4.11's 3.0 for a UI glyph carrying meaning.
        child: Icon(
          Icons.lock_outline,
          size: 16,
          color: AppPalette.textSecondary,
        ),
      );
    }

    if (group != null) {
      return IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        color: AppPalette.textSecondary,
        tooltip: 'Delete from this computer',
        visualDensity: VisualDensity.compact,
        onPressed: () => _confirmAndDelete(context, ref, group),
      );
    }

    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;
    return TextButton.icon(
      onPressed: pulling
          ? null
          : () => ref
                .read(modelPullControllerProvider.notifier)
                .pull(model.catalog!.pullSpec),
      icon: const Icon(Icons.download_outlined, size: AppControl.iconSize),
      label: const Text('Get'),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
      ),
    );
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    ModelGroup group,
  ) async {
    final theme = Theme.of(context);
    final partsNote = group.isSplit
        ? ' All ${group.partCount} parts will be removed.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          '"${model.name}" will be removed from this computer.$partsNote '
          'You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await ref
        .read(modelDeleteControllerProvider.notifier)
        .delete(group.fileNames, label: group.displayName);
    if (ok || !context.mounted) return;
    final state = ref.read(modelDeleteControllerProvider);
    final message = state is ModelDeleteFailed
        ? state.message
        : "Couldn't delete this model. Please try again.";
    ToastScope.show(
      context,
      ToastSpec(message: message, severity: ToastSeverity.error),
    );
  }
}
