import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/models_providers.dart';

/// Step 4 (the main provider action): serve a locally pulled GGUF model via
/// `grid provider start --network <net> --model <gguf> [--advertise-as]`.
class ServeLocalCard extends ConsumerStatefulWidget {
  const ServeLocalCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ServeLocalCard> createState() => _ServeLocalCardState();
}

class _ServeLocalCardState extends ConsumerState<ServeLocalCard> {
  final _advertise = TextEditingController();
  String? _model;

  @override
  void dispose() {
    _advertise.dispose();
    super.dispose();
  }

  void _start() {
    ref.read(providerRunControllerProvider.notifier).startLocal(
          network: widget.network.networkId,
          model: _model!,
          advertiseAs: _advertise.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = ref.watch(localModelsProvider);

    if (models.isEmpty) {
      return Text(
        'No local model yet — pull one above first.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    // Default to the first model; keep selection valid if the list changes.
    final names = models.map((m) => m.name).toList();
    final selected = names.contains(_model) ? _model : names.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: selected,
          decoration: const InputDecoration(
            labelText: 'Local model (--model)',
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
            labelText: 'Advertise as (optional, --advertise-as)',
            hintText: 'Qwen3.6-35B-A3B',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () {
              _model ??= selected;
              _start();
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start provider'),
          ),
        ),
      ],
    );
  }
}
