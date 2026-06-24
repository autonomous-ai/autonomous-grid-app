import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../logic/backend_detector.dart';
import '../logic/provider_run_controller.dart';
import 'provider_running_card.dart';

/// Provider lifecycle. Enables the provider role when missing, then serves a
/// model — from a local GGUF (the main flow) or an external OpenAI-compatible
/// endpoint (`--at`) — and monitors the running provider. Model management
/// (backends, pull, local files) lives on the Models tab.
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

  void _use(DetectedBackend backend) {
    setState(() {
      _endpoint.text = backend.baseUrl;
      _suggestedModels = backend.models;
      if (backend.models.length == 1) _model.text = backend.models.first;
    });
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

    return SectionScaffold(
      title: 'Provider',
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
      return const Text('No grid joined yet.');
    }
    if (!network.isProvider) {
      return EnableProviderCard(network: network);
    }
    if (run is ProviderRunActive) {
      return ProviderRunningCard(
          starting: run.starting, log: run.log, logHeight: 420);
    }

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
        _subheading(theme, 'Serve a local model'),
        ServeLocalCard(network: network),
        const SizedBox(height: 20),
        _subheading(theme, 'Or use an external endpoint (--at)'),
        _ExternalRunForm(
          network: network,
          endpoint: endpoint,
          model: model,
          advertise: advertise,
          suggestedModels: suggestedModels,
          onUse: onUse,
          onStart: onStart,
        ),
      ],
    );
  }

  Widget _subheading(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backends = ref.watch(backendsProvider).asData?.value ?? const [];
    final external = backends.where((b) => b.isExternal).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                label: const Text('Start (external)'),
              );
            },
          ),
        ),
      ],
    );
  }
}
