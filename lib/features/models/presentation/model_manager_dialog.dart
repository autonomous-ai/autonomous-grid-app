import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/local_files.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/models_providers.dart';
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
    final models = ref.watch(localModelsProvider);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _DialogHeader(),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 20),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const _SectionLabel('Download a model'),
                    const SizedBox(height: 12),
                    const ModelPullCard(),
                    const SizedBox(height: 28),
                    _SectionLabel(
                      'Downloaded models',
                      trailing: models.isEmpty ? null : '${models.length}',
                    ),
                    const SizedBox(height: 12),
                    _DownloadedList(models: models),
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
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
  const _DownloadedList({required this.models});

  final List<LocalModel> models;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: models.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              child: Text(
                'No models downloaded yet — download one above.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : Column(children: _rows()),
    );
  }

  List<Widget> _rows() {
    final rows = <Widget>[];
    for (var i = 0; i < models.length; i++) {
      rows.add(_ModelTile(model: models[i]));
      if (i != models.length - 1) {
        rows.add(const Divider(height: 1, indent: 14, endIndent: 14));
      }
    }
    return rows;
  }
}

/// One downloaded model: an icon tile, the file name, and its size on the right.
class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model});

  final LocalModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            child: Text(
              model.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${model.sizeGb.toStringAsFixed(2)} GB',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
