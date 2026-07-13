import 'package:flutter/material.dart';

/// The "Model name shown to the grid" field — the name a served model is
/// announced under on the grid (the `grid` CLI's `--advertise-as`). It's what
/// other people on the grid see and pick when they want to use this model, and
/// it does not have to match the model's filename. A help tooltip spells that
/// out inline for first-time users.
class AdvertiseAsField extends StatelessWidget {
  const AdvertiseAsField({
    super.key,
    required this.controller,
    this.hintText,
    this.optional = false,
  });

  /// Source of truth for the advertised name; the parent reads it on Start.
  final TextEditingController controller;

  /// Example name shown when the field is empty.
  final String? hintText;

  /// Appends "(optional)" to the label when leaving it blank is fine (the parent
  /// either omits the flag or falls back to a name derived from the model).
  final bool optional;

  /// Plain-language explanation of `--advertise-as`, drawn from the CLI README:
  /// it sets the model name advertised to (and requested by) consumers on the
  /// network, and need not match a local file.
  static const _tooltip =
      'This is the model name other grid clients will see when routing '
      'requests to your machine.';

  /// The field label; the same concept whether or not the flag is optional.
  static const _label = 'Model name shown to the grid';

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: optional ? '$_label (optional)' : _label,
        hintText: hintText,
        border: const OutlineInputBorder(),
        suffixIcon: Tooltip(
          message: _tooltip,
          child: const Icon(Icons.help_outline, size: 18),
        ),
      ),
    );
  }
}
