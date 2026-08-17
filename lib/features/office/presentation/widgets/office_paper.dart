import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';

/// The document itself: one page of editable text, on a desk.
///
/// Text only, on purpose — this is the first version of Docs, and it says what
/// it is by having no toolbar to promise otherwise. What it does keep is the
/// *shape* of a document: a page of a printed width, wide margins, and paper
/// that stays paper in dark mode (see [AppPalette.paper]).
class OfficePaper extends ConsumerStatefulWidget {
  const OfficePaper({super.key, required this.doc});

  final OfficeDocOpen doc;

  /// A Letter page at 96dpi. The number matters less than the ceiling: a line of
  /// text that runs the width of a 27" monitor is unreadable, and every word
  /// processor answers that the same way.
  static const _pageWidth = 816.0;

  /// Enough page under the last line that a three-line document still reads as a
  /// document rather than as a text box.
  static const _pageMinHeight = 560.0;

  @override
  ConsumerState<OfficePaper> createState() => _OfficePaperState();
}

class _OfficePaperState extends ConsumerState<OfficePaper> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.doc.text);
  }

  @override
  void didUpdateWidget(OfficePaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a *fresh opening* is allowed to overwrite what's in the field.
    // Pushing the controller's own value back on every rebuild would fight the
    // typist: every keystroke reaches the provider, comes back here, and would
    // reset the selection to the end of the text mid-word.
    //
    // Keyed on the opening, not the path: re-opening the file you have been
    // editing is how a person abandons their edits, and that arrives with the
    // same path and the text from disk.
    if (widget.doc.openId != oldWidget.doc.openId) {
      _text.value = TextEditingValue(text: widget.doc.text);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  // No `AppTheme.watch` in this build, unlike almost every other in the app —
  // and that absence *is* the rule: nothing on the page follows the theme, so
  // there is no palette subscription to keep. The desk behind it belongs to the
  // pane (see `_DocumentSide`), which does watch.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: OfficePaper._pageWidth,
            minHeight: OfficePaper._pageMinHeight,
          ),
          child: _Page(
            // Word's inch margin, given up as the pane narrows — held at 96px it
            // would be the whole width of a squeezed column, and a page with no
            // room left for text overflows instead of scrolling.
            inset: (constraints.maxWidth * 0.11).clamp(20.0, 96.0),
            child: _Body(controller: _text),
          ),
        ),
      ),
    ),
  );
}

/// The sheet: white, square-cornered, lifted off the desk by a soft shadow the
/// way every word processor draws a page.
class _Page extends StatelessWidget {
  const _Page({required this.inset, required this.child});

  final double inset;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppPalette.paper,
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A000000),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(inset, 64, inset, 72),
      child: child,
    ),
  );
}

/// The editable text on the page.
class _Body extends ConsumerWidget {
  const _Body({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Two things the app's own theme has to be told to keep off this page.
    //
    // The field decoration, first: `inputDecorationTheme` fills every field with
    // `surfaceContainerHighest` and rims it with a rounded border, which drew the
    // document as a grey form control sitting on the paper. Blanked wholesale
    // rather than overridden property by property — this is not a field with the
    // decoration turned down, it is a page, and the theme has `enabledBorder` and
    // `focusedBorder` that would each need answering separately.
    //
    // And the selection colours: the page is white in both themes, so dark mode's
    // cursor and selection tint — tuned for charcoal — all but disappear on it.
    return Theme(
      data: Theme.of(context).copyWith(
        inputDecorationTheme: const InputDecorationTheme(),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: AppPalette.accent,
          selectionColor: AppPalette.accent.withValues(alpha: 0.22),
          selectionHandleColor: AppPalette.accent,
        ),
      ),
      child: TextField(
        controller: controller,
        onChanged: (text) => ref.read(officeDocProvider.notifier).edit(text),
        maxLines: null,
        // Not autofocused: arriving on a screen with the caret already in the
        // document means the first keystroke edits somebody's file.
        style: const TextStyle(
          color: AppPalette.paperInk,
          fontSize: 15,
          height: 1.75,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          filled: false,
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
