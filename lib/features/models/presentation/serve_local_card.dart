import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/advertise_name.dart';
import '../logic/llama_install_controller.dart';
import '../logic/models_providers.dart';
import 'model_manager_dialog.dart';

/// The built-in llama.cpp engine block: serve a locally pulled GGUF model via
/// `grid join <grid> --serve <gguf> --advertise-as <name>`. Downloading and
/// managing models lives in the model manager ("Manage models"), opened here.
class ServeLocalCard extends ConsumerStatefulWidget {
  const ServeLocalCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ServeLocalCard> createState() => _ServeLocalCardState();
}

class _ServeLocalCardState extends ConsumerState<ServeLocalCard> {
  final _advertise = TextEditingController();
  String? _model;
  String? _advertiseFilledFor;

  @override
  void dispose() {
    _advertise.dispose();
    super.dispose();
  }

  /// Pre-fill the advertise field from the model name, once per selection — but
  /// keep the user's manual edits while the same model stays selected.
  void _syncAdvertiseFor(String model) {
    if (model == _advertiseFilledFor) return;
    _advertiseFilledFor = model;
    final derived = deriveAdvertiseName(model);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _advertise.text = derived;
    });
  }

  void _start(String model) {
    final advertise = _advertise.text.trim();
    // --advertise-as is always sent; derive from the model name if left blank.
    ref.read(providerRunControllerProvider.notifier).startLocal(
          network: widget.network.networkId,
          model: model,
          advertiseAs:
              advertise.isEmpty ? deriveAdvertiseName(model) : advertise,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = ref.watch(localModelsProvider);
    final llamaInstalled = ref.watch(engineStatusProvider).llamaInstalled;

    // Default to the first model; keep selection valid if the list changes.
    final names = models.map((m) => m.name).toList();
    final selected =
        names.contains(_model) ? _model! : (names.isEmpty ? null : names.first);
    if (selected != null) _syncAdvertiseFor(selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected == null) ...[
          // No models yet. If the engine is installed, downloading one is the
          // next step — make it a primary action, not a tucked-away link. Until
          // the engine is installed, the node setup above is the next step.
          if (llamaInstalled) ...[
            Text(
              'No models on this computer yet. Download one to start serving.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => showModelManager(context),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Download a model'),
              ),
            ),
          ] else
            Text(
              'Set this computer up as a node above, then download a model to serve.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ] else ...[
          ..._serveControls(names, selected),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showModelManager(context),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Manage models'),
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _serveControls(List<String> names, String selected) => [
        DropdownButtonFormField<String>(
          initialValue: selected,
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final name in names)
              DropdownMenuItem(value: name, child: Text(name)),
          ],
          onChanged: (value) => setState(() => _model = value),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _advertise,
          decoration: const InputDecoration(
            labelText: 'Display name',
            helperText: 'The name others on the grid will see. Edit if you like.',
            hintText: 'Qwen3.6-35B-A3B',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _start(selected),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start engine'),
          ),
        ),
      ];
}
