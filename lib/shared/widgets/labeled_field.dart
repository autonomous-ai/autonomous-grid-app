import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A field's label, sitting still above the control it names.
///
/// Material floats a `labelText` *inside* the field and animates it up to the
/// rim once the field has focus or a value — so a form ends up with its empty
/// fields wearing their labels as placeholder text while the filled ones wear
/// theirs tinted and notched into the border, which reads as focus that isn't
/// there. macOS doesn't move labels: it sets them above the control and leaves
/// them.
///
/// Split out of [LabeledField] so a dialog that has to build its own control (a
/// picker, a multiline box) still labels it the same way.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}

/// A labelled input: the label sits above a soft, borderless capsule field.
///
/// The shared form field for the app's dialogs — roomier and calmer than a
/// floating-label box, so several stacked don't read as a wall. Style tokens
/// come from [AppPalette] so it tracks the theme in light and dark.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    this.enabled = true,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        TextField(
          controller: controller,
          enabled: enabled,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 14, height: 1.4),
          decoration: labeledFieldDecoration(hint),
        ),
      ],
    );
  }
}

/// The soft, borderless field surface — filled with the card tint, rounded, and
/// one accent hairline only while focused. Exposed so a field that needs its own
/// `TextField` (multiline, custom actions) still matches [LabeledField].
InputDecoration labeledFieldDecoration(String hint) {
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: width == 0
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: AppPalette.cardBg,
    hintStyle: TextStyle(
      fontSize: 14,
      height: 1.4,
      color: AppPalette.textFaint,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: border(Colors.transparent, 0),
    enabledBorder: border(Colors.transparent, 0),
    disabledBorder: border(Colors.transparent, 0),
    focusedBorder: border(AppPalette.accent, 1.5),
  );
}
