import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/local_files.dart';
import '../../../shared/widgets/log_view.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/engine_status.dart';
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
      subtitle: '${models.length} local model(s) in ~/.grid/models',
      child: ListView(
        children: [
          _sectionTitle(context, 'Inference backends'),
          const _BackendsSection(),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Local models'),
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
          child: Text('No local GGUF models yet — pull one above.'),
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

/// Detected backends + the grid llama.cpp engine (install when missing).
class _BackendsSection extends ConsumerWidget {
  const _BackendsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineStatusProvider);
    final backends = ref.watch(backendsProvider);
    final installFailed =
        ref.watch(llamaInstallControllerProvider) is LlamaInstallFailed;

    return backends.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Scanning for Ollama / LM Studio / llama.cpp…'),
      ),
      error: (e, _) => Text('Scan failed: $e'),
      data: (list) {
        final external = list.where((b) => b.isExternal).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final backend in external)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.dns_outlined, color: Colors.green),
                  title: Text(backend.label),
                  subtitle: Text(
                      '${backend.baseUrl} · ${backend.models.length} model(s)'),
                ),
              ),
            _LlamaCard(engine: engine, failed: installFailed),
            if (external.isEmpty && !engine.llamaInstalled)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No running server found (Ollama :11434, '
                    'LM Studio :1234). Install llama.cpp, or start your own.'),
              ),
          ],
        );
      },
    );
  }
}

class _LlamaCard extends ConsumerWidget {
  const _LlamaCard({required this.engine, required this.failed});
  final EngineStatus engine;
  final bool failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = engine.llamaInstalled;
    return Card(
      child: ListTile(
        leading: Icon(
          installed ? Icons.check_circle : Icons.download_outlined,
          color: installed ? Colors.green : null,
        ),
        title: const Text('llama.cpp (grid engine)'),
        subtitle: Text(installed
            ? (engine.llamaPath ?? 'installed')
            : failed
                ? 'install failed — retry'
                : 'not installed'),
        trailing: installed
            ? null
            : FilledButton(
                onPressed: () =>
                    ref.read(llamaInstallControllerProvider.notifier).install(),
                child: Text(failed ? 'Retry' : 'Install'),
              ),
      ),
    );
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
            Text('Installing llama.cpp…'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: LogView(lines: log)),
      ],
    );
  }
}
