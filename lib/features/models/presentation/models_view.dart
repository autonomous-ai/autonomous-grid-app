import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/local_files.dart';
import '../../../shared/widgets/log_view.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/llama_install_controller.dart';
import '../logic/models_providers.dart';
import 'model_pull_card.dart';

/// Models & backends hub: detect inference backends (Ollama, LM Studio, grid's
/// llama.cpp), install llama.cpp, and pull/list local GGUF models. Serving a
/// provider with these models lives on the Provider tab.
class ModelsView extends ConsumerWidget {
  const ModelsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(llamaInstallControllerProvider);
    final models = ref.watch(localModelsProvider);

    // While llama.cpp installs, take over the pane with the live log.
    if (install is LlamaInstalling) {
      return SectionScaffold(
        title: 'Models',
        child: _InstallingPane(log: install.log),
      );
    }

    return SectionScaffold(
      title: 'Models',
      subtitle: '${models.length} model(s) on this computer',
      child: ListView(
        children: [
          const NodeSetupCard(),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Downloaded models'),
          const ModelPullCard(),
          const SizedBox(height: 16),
          ..._localModels(models),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  List<Widget> _localModels(List<LocalModel> models) {
    if (models.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No models downloaded yet — download one above.'),
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

class _InstallingPane extends StatelessWidget {
  const _InstallingPane({required this.log});
  final List<String> log;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: const [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Installing the built-in engine…'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: LogView(lines: log)),
      ],
    );
  }
}
