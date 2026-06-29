import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/backend_detector.dart';
import '../logic/provider_run_controller.dart';
import 'provider_running_card.dart';

/// Provider lifecycle. Enables the provider role when missing, then serves a
/// model — from a local GGUF (the main flow) or an external OpenAI-compatible
/// endpoint (`--at`) — and monitors the running provider. Downloading and
/// managing local models lives inline in the local engine block.
class ProviderView extends ConsumerStatefulWidget {
  const ProviderView({super.key});

  @override
  ConsumerState<ProviderView> createState() => _ProviderViewState();
}

class _ProviderViewState extends ConsumerState<ProviderView> {
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

  /// Pick a detected framework and pre-fill every field — address, model (the
  /// first one it reports) and a derived display name — so it's one tap to start.
  void _use(DetectedBackend backend) {
    final model = backend.models.isEmpty ? '' : backend.models.first;
    _endpoint.text = backend.baseUrl;
    _model.text = model;
    _advertise.text =
        model.isEmpty ? backend.label : deriveAdvertiseName(model);
    setState(() => _suggestedModels = backend.models);
  }

  void _startExternal(NetworkCredential network) {
    ref.read(providerRunControllerProvider.notifier).startExternal(
          network: network.networkId,
          endpoint: _endpoint.text.trim(),
          model: _model.text.trim(),
          advertiseAs: _advertise.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(selectedNetworkProvider);

    // Reflect an engine that's still serving this grid (e.g. one that outlived
    // an app restart). Runs after the frame so it never mutates state mid-build;
    // the controller dedupes per grid.
    if (network != null) {
      final notifier = ref.read(providerRunControllerProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.reconcile(network.networkId);
      });
    }

    return SectionScaffold(
      title: 'Engines',
      subtitle: network?.name,
      child: ListView(
        children: [
          _ServeSection(
            endpoint: _endpoint,
            model: _model,
            advertise: _advertise,
            suggestedModels: _suggestedModels,
            onUse: _use,
            onStart: _startExternal,
          ),
        ],
      ),
    );
  }
}

/// Gates on network/provider/run-state, then offers the local-model serve (the
/// main flow) with the BYO external `--at` form as a secondary option.
class _ServeSection extends ConsumerWidget {
  const _ServeSection({
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
      return const Text("You haven't joined a grid yet.");
    }
    if (!network.isProvider) {
      return EnableProviderCard(network: network);
    }
    if (run is ProviderRunActive && run.grid == network.networkId) {
      return ProviderRunningCard(
          starting: run.starting, log: run.log, logHeight: 420);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (run is ProviderRunFailed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("Couldn't start last time: ${run.message}",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        // Set this computer up as a node — installs llama.cpp and anything else
        // missing. Lives here (not in the model manager) so the engine prereqs
        // are visible up front.
        const NodeSetupCard(),
        const SizedBox(height: 16),
        _EngineBlock(
          icon: Icons.dns_outlined,
          title: 'llama.cpp',
          subtitle: 'Built-in engine — serve a local model from this computer',
          child: ServeLocalCard(network: network),
        ),
        const SizedBox(height: 16),
        _EngineBlock(
          icon: Icons.lan_outlined,
          title: 'Connect your own server',
          subtitle:
              'Use a framework running on this machine, or any OpenAI-compatible endpoint',
          child: _ExternalRunForm(
            network: network,
            endpoint: endpoint,
            model: model,
            advertise: advertise,
            suggestedModels: suggestedModels,
            onUse: onUse,
            onStart: onStart,
          ),
        ),
      ],
    );
  }
}

/// A titled engine block — a card with an icon + title header so the two serve
/// paths (built-in llama.cpp vs. your own server) are easy to tell apart.
class _EngineBlock extends StatelessWidget {
  const _EngineBlock({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// The BYO external OpenAI-compatible endpoint form (`provider start --at`).
class _ExternalRunForm extends ConsumerWidget {
  const _ExternalRunForm({
    required this.network,
    required this.endpoint,
    required this.model,
    required this.advertise,
    required this.suggestedModels,
    required this.onUse,
    required this.onStart,
  });

  final NetworkCredential network;
  final TextEditingController endpoint;
  final TextEditingController model;
  final TextEditingController advertise;
  final List<String> suggestedModels;
  final void Function(DetectedBackend) onUse;
  final void Function(NetworkCredential) onStart;

  /// Model is a dropdown when the chosen framework reports models (pick one of
  /// many), and a free-text field otherwise (manual base URL → type the name).
  /// The [model] controller stays the source of truth so [onStart] reads it.
  Widget _modelField() {
    if (suggestedModels.isEmpty) {
      return TextField(
        controller: model,
        decoration: const InputDecoration(
          labelText: 'Model',
          hintText: 'gemma4-31b',
          border: OutlineInputBorder(),
        ),
      );
    }
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final value = suggestedModels.contains(model.text) ? model.text : null;
        return DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final m in suggestedModels)
              DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (v) {
            if (v != null) model.text = v;
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backends = ref.watch(backendsProvider).asData?.value ?? const [];
    final external = backends.where((b) => b.isExternal).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (external.isNotEmpty) ...[
          _DetectedFrameworkList(backends: external, onUse: onUse),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'http://192.168.1.10:8080/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        _modelField(),
        const SizedBox(height: 12),
        TextField(
          controller: advertise,
          decoration: const InputDecoration(
            labelText: 'Display name (optional)',
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
                label: const Text('Start engine'),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Frameworks detected running on this machine (Ollama, LM Studio, …), shown as
/// a pick list. Tapping one fills the address, model and display name below.
class _DetectedFrameworkList extends StatelessWidget {
  const _DetectedFrameworkList({required this.backends, required this.onUse});

  final List<DetectedBackend> backends;
  final void Function(DetectedBackend) onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Detected on this machine',
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        for (final backend in backends)
          Card.outlined(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(backend.label),
              subtitle: Text(_subtitle(backend)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onUse(backend),
            ),
          ),
      ],
    );
  }

  /// e.g. `localhost:11434/v1 · 3 models`.
  String _subtitle(DetectedBackend backend) {
    final host = backend.baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    final count = backend.models.length;
    final models =
        count == 0 ? 'no models reported' : '$count model${count == 1 ? '' : 's'}';
    return '$host · $models';
  }
}
