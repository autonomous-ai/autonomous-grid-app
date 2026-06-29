import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/advertise_name.dart';
import '../logic/models_providers.dart';

/// Step 4 (the main provider action): serve a locally pulled GGUF model via
/// `grid join <grid> --serve <gguf> --advertise-as <name>`.
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

    if (models.isEmpty) {
      return Text(
        'No models on this computer yet — download one above first.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    // Default to the first model; keep selection valid if the list changes.
    final names = models.map((m) => m.name).toList();
    final selected = names.contains(_model) ? _model! : names.first;
    _syncAdvertiseFor(selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            label: const Text('Start sharing'),
          ),
        ),
      ],
    );
  }
}
