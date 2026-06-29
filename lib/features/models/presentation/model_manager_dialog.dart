import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/local_files.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/models_providers.dart';

/// "Manage models" — the model hub that used to be its own tab: this computer's
/// node-setup status plus every GGUF already downloaded under `~/.grid/models`.
/// Opened from the local engine block; downloading new models lives there.
Future<void> showModelManager(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ModelManagerDialog(),
    );

class _ModelManagerDialog extends ConsumerWidget {
  const _ModelManagerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final models = ref.watch(localModelsProvider);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Manage models',
                        style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const NodeSetupCard(),
                    const SizedBox(height: 16),
                    Text('Downloaded models',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ..._localModels(models),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _localModels(List<LocalModel> models) {
    if (models.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child:
              Text('No models downloaded yet — download one from the engine.'),
        ),
      ];
    }
    return [
      for (final model in models)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.memory_outlined),
          title: Text(model.name),
          trailing: Text('${model.sizeGb.toStringAsFixed(2)} GB'),
        ),
    ];
  }
}
