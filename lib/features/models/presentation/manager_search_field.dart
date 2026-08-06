import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';

/// The model manager's filter box — a recessed capsule with a leading glass and
/// a clear button once there's something to clear.
///
/// A [LabeledField] would be wrong here: its label sits *above* the control (§3),
/// which is right for a form and wrong for a toolbar control sharing a row with
/// the tab switch — the label would push the switch out of alignment for no
/// gain, since a magnifier already says what the box is.
///
/// ### Fill
///
/// [AppCard.inset], not the default [AppPalette.cardBg]. Measured against the
/// dialog's own surface (`menuFill`, `#1E1E1E` dark / white light):
///
/// ```
/// dark   dialog #1E1E1E vs cardBg #1E1E1E = 1.000 : 1   ← identical
/// dark   dialog #1E1E1E vs inset  #181818 = 1.065 : 1
/// light  dialog #FFFFFF vs cardBg #F3F3F2 = 1.110 : 1
/// light  dialog #FFFFFF vs inset  #F7F7F5 = 1.073 : 1
/// ```
///
/// `cardBg` is *the same colour as the dialog* in dark — the box would have no
/// edge whatsoever. `inset` recesses in both, which is the point of a search
/// field: it reads as a well you type into.
class ManagerSearchField extends StatelessWidget {
  const ManagerSearchField({
    super.key,
    required this.controller,
    required this.hint,
  });

  final TextEditingController controller;
  final String hint;

  /// No `onSubmitted`: the box is multiline (below), so Enter inserts a newline
  /// and the callback would never fire. A pasted spec is acted on by the
  /// Download row it raises, not by the keyboard.
  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      // Fixed, and equal to the segmented switch beside it. An earlier version
      // let the box grow (`minLines: 1, maxLines: 4`) so a pasted split GGUF
      // could be read in full — but a growing box on a toolbar strip drags its
      // own edges away from the control it sits next to. Measured: 32px empty,
      // **48px** with one long line wrapped, **64px** with two lines, against a
      // switch fixed at 32. The screenshot showed it; the first geometry test
      // missed it because it only measured an empty box.
      //
      // `maxLines: 1` is what keeps the text on one line. `maxLines: null` (with
      // `expands`) was tried first, to keep a split GGUF's newlines — but it
      // soft-wraps, and a long repo name is *long*: laid out at this field's
      // ~246px of glyph width, the name in the screenshot wrapped to **5 lines,
      // 80px tall**, inside a 32px box. It spilled straight out of the capsule.
      //
      // Newlines survive anyway. `maxLines: 1` only strips them from *typing* —
      // a real paste sets the controller's value wholesale and arrives intact,
      // verified by assigning `TextEditingValue(text: 'a\nb')` and reading
      // `'a\nb'` back. (`tester.enterText` simulates typing, so a widget test
      // sees `'ab'` and is the wrong instrument for this question.)
      height: AppControl.height,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          controller: controller,
          maxLines: 1,
          keyboardType: TextInputType.multiline,
          // 13pt explicitly: InputDecorationTheme has no `style` slot, so a bare
          // TextField takes Material's 16pt and stands out beside every other
          // control in the app.
          style: TextStyle(
            fontSize: 13,
            height: 1.2,
            color: AppPalette.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: AppPalette.textFaint,
            ),
            filled: true,
            fillColor: AppCard.inset,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 16,
              color: AppPalette.textFaint,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: AppIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Clear',
                      onPressed: controller.clear,
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
            border: _border(Colors.transparent, 0),
            enabledBorder: _border(Colors.transparent, 0),
            // The one place the field draws an edge — focus, at 1.5px, matching
            // labeledFieldDecoration so every field in the app focuses alike.
            focusedBorder: _border(AppPalette.accent, 1.5),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        // 8, not the 12 of labeledFieldDecoration: this field is a control on a
        // toolbar strip, sized and shaped like the segmented switch beside it
        // (AppControl.radius), not a form field in a column.
        borderRadius: BorderRadius.circular(AppControl.radius),
        borderSide: width == 0
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );
}
