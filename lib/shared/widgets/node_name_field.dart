import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'labeled_field.dart';

/// The "This computer's name on the grid" field — what this machine is called on
/// the grid page while it is serving (the `grid` CLI's `--name`).
///
/// Pre-filled from the computer's own name, which is right for most people and
/// wrong for anyone running two machines that macOS named the same thing, or
/// serving from a box whose hostname says nothing about who owns it. Purely a
/// label: the CLI keys its run records by its own engine id, so renaming here
/// changes what people read, not what stops when you press Stop.
class NodeNameField extends StatelessWidget {
  const NodeNameField({super.key, required this.controller, this.hintText});

  /// Source of truth for the name; the parent reads it on Start and falls back
  /// to the computer's own name when it is left blank.
  final TextEditingController controller;

  /// Example name shown when the field is empty.
  final String? hintText;

  static const _tooltip =
      'How this computer appears on the grid, so you can tell your machines '
      'apart. It does not change which models you serve.';

  /// Paired with [AdvertiseAsField]'s, and trimmed for the same reason: the two
  /// sit side by side, and "on the grid" is what the field above it already
  /// establishes both names are for.
  static const _label = "This computer's name";

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Label above the control, borderless capsule below — the app's form idiom
    // (see labeled_field.dart), and the same shape as [AdvertiseAsField] right
    // beside it, because they are the same kind of question.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(_label),
        TextField(
          controller: controller,
          style: kFieldTextStyle,
          decoration:
              labeledFieldDecoration(
                hintText ?? '',
                fill: AppCard.inset,
              ).copyWith(
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  maxWidth: 40,
                  maxHeight: 44,
                ),
                suffixIcon: Tooltip(
                  message: _tooltip,
                  child: Icon(
                    Icons.help_outline,
                    size: kFieldIconSize,
                    color: AppPalette.textFaint,
                  ),
                ),
              ),
        ),
      ],
    );
  }
}
