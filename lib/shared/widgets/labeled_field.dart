import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          fontWeight: AppFont.medium,
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
    this.onSubmitted,
    this.inputFormatters,
    this.fill,
    this.error,
    this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  /// Live input rules — e.g. turning a typed space into `-` so a prompt name
  /// stays one slash-command as the user types it.
  final List<TextInputFormatter>? inputFormatters;

  /// Enter confirms. Only meaningful on a single-line field — in a multiline
  /// box Enter inserts a newline and this never fires.
  final ValueChanged<String>? onSubmitted;

  /// Overrides the field surface — see [labeledFieldDecoration]. Pass this when
  /// the field sits on a *raised* block rather than the page: the default
  /// [AppPalette.cardBg] is within 1.02:1 of `AppGlass.surfaceFill` in dark and
  /// disappears into it.
  final Color? fill;

  /// What's wrong with the current value, shown under the field in the error ink
  /// with the border to match. Null when there is nothing wrong.
  ///
  /// The caller decides *when* to pass it, and that timing matters more than the
  /// wording: a field that reddens on the first keystroke is a field people
  /// fight. Validate on blur or on submit, not on every character.
  final String? error;

  /// Handed in when the caller needs to know about focus — the usual reason
  /// being to decide when [error] should appear.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens through its decoration — follow theme flips.
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          inputFormatters: inputFormatters,
          style: const TextStyle(fontSize: 14, height: 1.4),
          decoration: labeledFieldDecoration(
            hint,
            fill: fill,
            hasError: error != null,
          ),
        ),
        if (error != null) _FieldError(error!),
      ],
    );
  }
}

/// The soft, borderless field surface — filled with the card tint, rounded, and
/// one accent hairline only while focused. Exposed so a field that needs its own
/// `TextField` (multiline, custom actions) still matches [LabeledField].
///
/// [fill] overrides the surface for a field sitting on something lighter than
/// the usual ground. The default [AppPalette.cardBg] is picked to read against
/// a dialog or the window; on a raised block (`AppGlass.surfaceFill`, #202020 in
/// dark) it lands within 1.02:1 of its own container and effectively vanishes.
/// Such callers pass [AppCard.inset], which recesses properly against it.
InputDecoration labeledFieldDecoration(
  String hint, {
  Color? fill,
  bool hasError = false,
}) {
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
    fillColor: fill ?? AppPalette.cardBg,
    hintStyle: TextStyle(
      fontSize: 14,
      height: 1.4,
      color: AppPalette.textFaint,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    // The error hairline shows whether or not the field has focus — an error the
    // user has to click back into the field to see is an error they won't see.
    border: border(Colors.transparent, 0),
    enabledBorder: hasError
        ? border(fieldErrorInk(), 1.5)
        : border(Colors.transparent, 0),
    disabledBorder: border(Colors.transparent, 0),
    focusedBorder: border(hasError ? fieldErrorInk() : AppPalette.accent, 1.5),
  );
}

/// The error red for a field's hairline and its message.
///
/// `colorScheme.error` itself, unlike `AppIconButton`'s danger ink — and the
/// difference is the *ground*, not the shade. That button's red sits on its own
/// hover fill (`#3A3A3A`), where the token reaches only 3.33:1; a field's error
/// sits on whatever the field sits on, and there the token has room everywhere it
/// can land (measured 2026-07-30):
///
/// ```
///          windowBg   panelBg    dialog    cardBg
/// dark      5.79       5.39       4.77      4.88
/// light     6.20       6.20       6.54      5.89
/// ```
///
/// Worth writing down because the first version of this invented a lighter red
/// on the assumption the token would fail here. It doesn't, and a second red in
/// the palette earns nothing.
Color fieldErrorInk() =>
    AppTheme.pick(const Color(0xFFB3261E), const Color(0xFFF2544B));

/// The message under a field in error.
class _FieldError extends StatelessWidget {
  const _FieldError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: fieldErrorInk()),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: fieldErrorInk(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dress a [DropdownButtonFormField]'s popup like the app's other menus.
///
/// `DropdownButtonFormField` reads **neither** `menuTheme` nor `popupMenuTheme`
/// — it renders its own `_DropdownMenu`, which takes its look from the widget's
/// own `dropdownColor` / `borderRadius` / `elevation` arguments. Left alone it
/// draws Material's default: square corners, full-bleed rows, no inset. On
/// macOS a menu is a floating rounded panel, so every dropdown in the app has to
/// be handed this.
///
/// Spread it into the widget:
/// ```dart
/// DropdownButtonFormField(
///   dropdownColor: appMenuFill(),
///   borderRadius: appMenuBorderRadius,
///   elevation: appMenuElevation,
///   ...
/// )
/// ```
/// The floating-menu surface, shared by [appMenuStyle] and every dropdown.
///
/// Lifted clear of both grounds a menu can open over: the window and a raised
/// block (`AppGlass.surfaceFill`, `#202020` in dark). The themed `menuFill`
/// (`#1E1E1E`) sits within 1.02:1 of that block, which left the panel with no
/// edge at all.
Color appMenuFill() => AppTheme.pick(Colors.white, const Color(0xFF2A2A2A));

/// Menu corner rounding — [AppControl.menuRadius], the same value
/// `popupMenuTheme` and `menuTheme` use, so all three kinds of menu agree.
final BorderRadius appMenuBorderRadius = BorderRadius.circular(
  AppControl.menuRadius,
);

/// Menu lift, matching `popupMenuTheme`/`menuTheme`.
const int appMenuElevation = 8;

/// A [MenuAnchor] surface that reads as *floating over* the page.
///
/// The themed default fill ([appMenuFill]) is `#1E1E1E` in dark — chosen against
/// the window, but a menu opened over a raised block (`AppGlass.surfaceFill`,
/// `#202020`) lands at 1.023:1 against it, and in light both are pure white:
/// the panel has no edge at all and the rows appear to float loose on the page.
///
/// So this lifts the fill above *both* grounds, adds the hairline the app uses
/// on other raised chrome, and deepens the shadow — the three things that
/// together say "this is a layer above". Pass it as a `MenuAnchor.style`.
MenuStyle appMenuStyle() {
  return MenuStyle(
    backgroundColor: WidgetStatePropertyAll(appMenuFill()),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(12),
    // Vertical breathing room only. Rows carry their own horizontal gutter so
    // their hover highlight reads as an inset pill; adding side padding here
    // would double it.
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 5)),
    // The cap lives in [AppControl] because the upward-opening menus need to
    // predict it: a panel placed by a taller estimate than it draws floats off
    // its button.
    maximumSize: const WidgetStatePropertyAll(
      Size.fromHeight(AppControl.menuMaxHeight),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        // In light the fill matches the card beneath it, so the rim is the only
        // thing drawing the panel's edge; in dark it firms up a lift that the
        // shadow alone renders too softly on near-black.
        side: BorderSide(color: AppGlass.hair),
      ),
    ),
  );
}
