import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/local_files.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/log_view.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../provider_node/logic/backend_detector.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../../provider_node/presentation/provider_running_card.dart';
import '../logic/engine_status.dart';
import '../logic/llama_install_controller.dart';
import '../logic/models_providers.dart';

/// Models & backends hub (Sprint 3). Detects existing inference backends
/// (Ollama, LM Studio, grid's llama.cpp), installs llama.cpp when none is
/// present, and lets the user serve a provider from an existing endpoint
/// (`grid provider start --at`) — no GGUF re-download.
class ModelsView extends ConsumerStatefulWidget {
  const ModelsView({super.key});

  @override
  ConsumerState<ModelsView> createState() => _ModelsViewState();
}

class _ModelsViewState extends ConsumerState<ModelsView> {
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _advertise = TextEditingController();
  List<String> _suggestedModels = const [];

  @override
  void dispose() {
    _endpoint.dispose();
    _model.dispose();
    _advertise.dispose();
    super.dispose();
  }

  void _use(DetectedBackend backend) {
    setState(() {
      _endpoint.text = backend.baseUrl;
      _suggestedModels = backend.models;
      if (backend.models.length == 1) _model.text = backend.models.first;
    });
  }

  void _start(NetworkCredential network) {
    ref.read(providerRunControllerProvider.notifier).startExternal(
          network: network.networkId,
          endpoint: _endpoint.text.trim(),
          model: _model.text.trim(),
          advertiseAs: _advertise.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
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
          _sectionTitle(context, 'Run provider from a backend'),
          _ProviderRunSection(
            endpoint: _endpoint,
            model: _model,
            advertise: _advertise,
            suggestedModels: _suggestedModels,
            onUse: _use,
            onStart: _start,
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Local models'),
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
          child: Text('No local GGUF models. Pull one with '
              '`grid models pull <repo>:<file>` (in-app pull — next).'),
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
    final installFailed = ref.watch(llamaInstallControllerProvider) is LlamaInstallFailed;

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

/// Either the BYO `--at` form, or the running provider card.
class _ProviderRunSection extends ConsumerWidget {
  const _ProviderRunSection({
    required this.endpoint,
    required this.model,
    required this.advertise,
    required this.suggestedModels,
    required this.onUse,
    required this.onStart,
  });

  final TextEditingController endpoint;
  final TextEditingController model;
  final TextEditingController advertise;
  final List<String> suggestedModels;
  final void Function(DetectedBackend) onUse;
  final void Function(NetworkCredential) onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final network = ref.watch(selectedNetworkProvider);
    final run = ref.watch(providerRunControllerProvider);

    if (network == null) {
      return const Text('No network joined yet.');
    }
    if (!network.isProvider) {
      return Text(
        'This network token has no provider scope (provider:poll), '
        'so it cannot run a provider.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    if (run is ProviderRunActive) {
      return ProviderRunningCard(starting: run.starting, log: run.log);
    }

    final backends = ref.watch(backendsProvider).asData?.value ?? const [];
    final external = backends.where((b) => b.isExternal).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (run is ProviderRunFailed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Last run failed: ${run.message}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        if (external.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final backend in external)
                ActionChip(
                  avatar: const Icon(Icons.dns_outlined, size: 16),
                  label: Text('Use ${backend.label}'),
                  onPressed: () => onUse(backend),
                ),
            ],
          ),
        const SizedBox(height: 12),
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Endpoint (--at)',
            hintText: 'http://192.168.1.10:8080/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: model,
          decoration: InputDecoration(
            labelText: 'Model (--model)',
            hintText: 'gemma4-31b',
            border: const OutlineInputBorder(),
            helperText: suggestedModels.isEmpty
                ? null
                : 'Detected: ${suggestedModels.take(5).join(', ')}',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: advertise,
          decoration: const InputDecoration(
            labelText: 'Advertise as (optional, --advertise-as)',
            hintText: 'mac-studio',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: Listenable.merge([endpoint, model]),
            builder: (context, _) {
              final canStart = endpoint.text.trim().isNotEmpty &&
                  model.text.trim().isNotEmpty;
              return FilledButton.icon(
                onPressed: canStart ? () => onStart(network) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start provider'),
              );
            },
          ),
        ),
      ],
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
