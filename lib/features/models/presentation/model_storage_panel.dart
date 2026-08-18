import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../node_setup/logic/background_model_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_download_status.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_storage.dart';
import '../logic/models_providers.dart';
import 'model_storage_row.dart';

/// "Models on this computer": everything taking up space, biggest first, each
/// with what it costs and a way to remove it.
///
/// It exists because the only delete used to sit behind a catalog model's
/// version list — findable only if the catalog still lists that model, and
/// blind to the biggest thing on most disks: downloads that stopped partway. Those
/// `.gguf.part` files are pure loss (they can't be served), and nothing in the
/// app could remove them.
class ModelStoragePanel extends ConsumerStatefulWidget {
  const ModelStoragePanel({super.key});

  @override
  ConsumerState<ModelStoragePanel> createState() => _ModelStoragePanelState();
}

class _ModelStoragePanelState extends ConsumerState<ModelStoragePanel> {
  @override
  void initState() {
    super.initState();
    // A delete that failed earlier in the session has been read by now. Post
    // frame, because clearing it is a state change and this is a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(modelDeleteControllerProvider.notifier).clearFailure();
    });
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final items = ref.watch(storedItemsProvider);
    final deleteState = ref.watch(modelDeleteControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('On this computer', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                items.isEmpty
                    ? 'Models you download live here. Nothing yet.'
                    : '${storageSummary(items)}. Deleting one frees its space '
                          'right away.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              if (deleteState case ModelDeleteFailed(:final message)) ...[
                const SizedBox(height: 10),
                ErrorBox(message: message, maxHeight: 72),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.folder_open_outlined,
                  title: 'No models downloaded',
                  message:
                      'Pick a model on the left and download it — it shows up '
                      'here with the space it uses.',
                )
              : _StoredList(items: items, deleteState: deleteState),
        ),
      ],
    );
  }
}

class _StoredList extends ConsumerWidget {
  const _StoredList({required this.items, required this.deleteState});

  final List<StoredItem> items;
  final ModelDeleteState deleteState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serving = ref.watch(servingModelProvider);
    // A `.part` being written right now must not be pulled out from under the
    // download writing it. Which of the three pullers is running doesn't
    // matter — that any is, does.
    final downloading =
        liveModelDownload(
          pull: ref.watch(modelPullControllerProvider),
          setup: ref.watch(nodeSetupControllerProvider),
          background: ref.watch(backgroundModelControllerProvider),
        ) !=
        null;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final item = items[i];
        return StoredModelRow(
          item: item,
          inUse: isStoredItemInUse(item, serving),
          downloadRunning: downloading,
          deleting: switch (deleteState) {
            ModelDeleting(:final label) => label == item.label,
            _ => false,
          },
        );
      },
    );
  }
}
