import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/modality_mark.dart';
import '../logic/playground_models.dart';

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
    final count = options.length;
    return DropdownMenu<String>(
      controller: controller,
      enableFilter: true,
      requestFocusOnTap: true,
      expandedInsets: EdgeInsets.zero,
      label: const Text('Model'),
      hintText: 'Qwen3.6-35B-A3B',
      // The menu's own text style, so a model id in the field is set in the
      // same face it wears everywhere else it can be copied — see [AppFont].
      textStyle: kFieldTextStyle,
      leadingIcon: const Icon(Icons.smart_toy_outlined, size: kFieldIconSize),
      menuStyle: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppControl.menuRadius),
          ),
        ),
      ),
      helperText: options.isEmpty
          ? 'No models available yet — type a name'
          // "4 option(s)" is the shape of a programmer dodging plurals; nobody
          // says it out loud. And "option" names the widget, not the thing —
          // these are models, which is the word the rest of the screen uses.
          : count == 1
          ? '1 model on $networkName'
          : '$count models on $networkName',
      dropdownMenuEntries: [
        for (final option in options)
          DropdownMenuEntry(
            value: option.id,
            label: option.label,
            leadingIcon: Icon(modelIcon(option), size: kFieldIconSize),
            style: MenuItemButton.styleFrom(textStyle: kFieldTextStyle),
          ),
      ],
      onSelected: (value) {
        if (value != null) controller.text = value;
      },
    );
  }
}
