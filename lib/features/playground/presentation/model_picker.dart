import 'package:flutter/material.dart';

import '../logic/playground_models.dart';
import '../logic/playground_request.dart';

/// Editable model dropdown — lists what the grid can do (chat models plus any
/// image / video generation modes, each with its own icon), yet stays typeable
/// so it still works when nothing can be fetched (no provider online, relay
/// down). Shared by the Playground dialog and the Chat tab.
class ModelPicker extends StatelessWidget {
  const ModelPicker({
    super.key,
    required this.controller,
    required this.options,
    required this.networkName,
  });

  final TextEditingController controller;
  final List<PlaygroundModelOption> options;
  final String networkName;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<String>(
      controller: controller,
      enableFilter: true,
      requestFocusOnTap: true,
      expandedInsets: EdgeInsets.zero,
      label: const Text('Model'),
      hintText: 'Qwen3.6-35B-A3B',
      leadingIcon: const Icon(Icons.smart_toy_outlined, size: 18),
      helperText: options.isEmpty
          ? 'No models available yet — type a name'
          : '${options.length} option(s) on $networkName',
      dropdownMenuEntries: [
        for (final option in options)
          DropdownMenuEntry(
            value: option.id,
            label: option.label,
            leadingIcon: Icon(_modalityIcon(option.modality), size: 18),
          ),
      ],
      onSelected: (value) {
        if (value != null) controller.text = value;
      },
    );
  }

  static IconData _modalityIcon(PlaygroundModality modality) =>
      switch (modality) {
        PlaygroundModality.image => Icons.image_outlined,
        PlaygroundModality.video => Icons.movie_outlined,
        PlaygroundModality.text => Icons.smart_toy_outlined,
      };
}
