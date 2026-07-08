import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_group.dart';
import '../logic/models_providers.dart';
import 'catalog_download_list.dart';
import 'model_pull_card.dart';

/// "Manage models" — the model hub that used to be its own tab: download a GGUF
/// and see every model already under `~/.grid/models`. Opened from the local
/// engine block. (Node setup / installing llama.cpp lives in the Engines tab.)
Future<void> showModelManager(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ModelManagerDialog(),
);

class _ModelManagerDialog extends ConsumerWidget {
  const _ModelManagerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(modelGroupsProvider);
    // Grow with the window (desktop app) so three stacked sections don't feel
    // cramped, but stay clear of the screen edges on smaller displays.
    final screen = MediaQuery.sizeOf(context);
    final maxWidth = screen.width < 800 ? screen.width - 96 : 720.0;
    final maxHeight = screen.height < 860 ? screen.height * 0.9 : 780.0;

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _DialogHeader(),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 24),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const _SectionLabel('Download a model'),
                    const SizedBox(height: 14),
                    const ModelPullCard(),
                    const SizedBox(height: 32),
                    const CatalogDownloadSection(),
                    _SectionLabel(
                      'Downloaded models',
                      trailing: groups.isEmpty ? null : '${groups.length}',
                    ),
                    const SizedBox(height: 14),
                    _DownloadedList(groups: groups),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title + one-line "what this is" subtitle + close, so the dialog opens with a
/// clear band of context instead of jumping straight into the form.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Manage models', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Download a model to serve, or see what\'s already on this '
                'computer.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// A section heading with an optional faint trailing count (e.g. how many models
/// are downloaded). Keeps the two sections visually consistent.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title, {this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// The models already under `~/.grid/models`, grouped in one bordered card with
/// divided rows so the list reads as a finished panel rather than loose lines.
/// Mirrors the detail-pane grouping (see `DetailSection`).
class _DownloadedList extends StatelessWidget {
  const _DownloadedList({required this.groups});

  final List<ModelGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      child: groups.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              child: Text(
                'No models downloaded yet — download one above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(children: _rows()),
    );
  }

  List<Widget> _rows() {
    final rows = <Widget>[];
    for (var i = 0; i < groups.length; i++) {
      rows.add(_ModelTile(group: groups[i]));
      if (i != groups.length - 1) {
        rows.add(const Divider(height: 1, indent: 14, endIndent: 14));
      }
    }
    return rows;
  }
}

/// One downloaded model: an icon tile, the model name, its size, and a delete
/// action. A split GGUF's parts read as one row ("5 parts") and delete as one.
/// A model the running engine is serving can't be deleted — its row shows a
/// "Running" badge instead, so files can't be pulled out from under a live engine.
class _ModelTile extends ConsumerWidget {
  const _ModelTile({required this.group});

  final ModelGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final serving = ref.watch(servingModelProvider);
    final inUse = group.fileNames.any((name) => isModelInUse(name, serving));
    final deleteState = ref.watch(modelDeleteControllerProvider);
    final deleting = deleteState is ModelDeleting &&
        deleteState.label == group.displayName;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppPalette.windowBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.memory_outlined, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                if (group.isSplit) ...[
                  const SizedBox(height: 2),
                  Text(
                    _partsLabel(group),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: group.isComplete
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${group.sizeGb.toStringAsFixed(2)} GB',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          _trailing(context, ref, theme, inUse: inUse, deleting: deleting),
        ],
      ),
    );
  }

  /// "5 parts" for a complete split set, or "3 of 5 parts — incomplete" when a
  /// part is missing (the engine can't serve it until every part is present).
  static String _partsLabel(ModelGroup group) {
    final expected = group.expectedParts;
    if (expected != null && group.partCount < expected) {
      return '${group.partCount} of $expected parts — incomplete';
    }
    return '${group.partCount} parts';
  }

  Widget _trailing(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme, {
    required bool inUse,
    required bool deleting,
  }) {
    if (deleting) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (inUse) {
      return Tooltip(
        message: 'In use by the running engine — stop it to delete this model.',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusDot(color: AppPalette.online, size: 7),
              const SizedBox(width: 6),
              Text(
                'Running',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.online,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.delete_outline, size: 18),
      color: AppPalette.textSecondary,
      tooltip: 'Delete model',
      visualDensity: VisualDensity.compact,
      onPressed: () => _confirmAndDelete(context, ref),
    );
  }

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final partsNote = group.isSplit
        ? ' All ${group.partCount} parts will be removed.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          '"${group.displayName}" will be removed from this computer.$partsNote '
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
