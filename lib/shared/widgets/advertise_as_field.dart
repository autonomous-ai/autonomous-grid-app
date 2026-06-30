import 'package:flutter/material.dart';

/// The "Advertise as" field — the name a served model is announced under on the
/// grid (the `grid` CLI's `--advertise-as`). It's what other people on the grid
/// see and pick when they want to use this model, and it does not have to match
/// the model's filename. The term mirrors the CLI on purpose, so a help tooltip
/// explains it inline for first-time users.
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
      'The name people on your grid see and pick to use this model. '
      "It doesn't have to match the model's filename.";

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: optional ? 'Advertise as (optional)' : 'Advertise as',
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
