import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
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
