import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/docx_format.dart';
import '../../logic/docx_paragraph_style.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';

part 'office_toolbar_controls.dart';

/// The strip that formats the paragraph the caret is in.
///
/// **Per paragraph, and it says so by what it holds.** Every control here
/// changes a property Word stores on the paragraph or on all of its runs, which
/// is exactly what `docx_style_write.dart` can put back without rebuilding
/// anything — so pressing Bold on a paragraph with a bold word in the middle
/// bolds the paragraph and loses nothing. What is missing is missing for that
/// reason: colour, highlight and bolding *three words* need a run under the
/// selection, which this editor has no model for yet (see the `TODO(BE)` in
/// `docx_edit.dart`). A button that only sometimes did what it looks like it
/// does would be worse than no button (§5).
///
/// Scrolls sideways rather than wrapping or shrinking. The document pane can be
/// squeezed to about 230px by the chat beside it, and a toolbar is a row of
/// fixed-width controls: there is no width at which they all still fit, so the
/// honest answer is to let the row run past the edge and be scrolled.
class OfficeToolbar extends ConsumerWidget {
  const OfficeToolbar({super.key, required this.doc});

  final OfficeDocOpen doc;

  static const height = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No `AppTheme.watch` here, and none in the rulers: every colour on this
    // bar is a `const` from the paper palette, so there is no theme flip to
    // follow. Adding the watch back would be watching for a change that cannot
    // reach it.
    final format = doc.formatAt(doc.caretLine);
    final apply = ref.read(officeDocProvider.notifier).applyStyle;
    return Column(
      // Stretch, or the bar is only as wide as its own controls: a `Column`
      // centres its children by default, and a scroll view sizes to what is in
      // it — so the light band floated in the middle of the pane with the desk
      // showing either side of it.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Light in both themes — see [AppPalette.paperChrome]. The bar belongs
        // to the page, not to the app around it.
        ColoredBox(
          color: AppPalette.paperChrome,
          child: SizedBox(
            height: height,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  _FontPicker(format: format, apply: apply),
                  const _Sep(),
                  _FontSize(format: format, apply: apply),
                  const _Sep(),
                  _Weight(format: format, apply: apply),
                  const _Sep(),
                  _Align(format: format, apply: apply),
                  const _Sep(),
                  _LineSpacing(format: format, apply: apply),
                  _Indent(format: format, apply: apply),
                ],
              ),
            ),
          ),
        ),
        // Not a themed `Divider`: it closes a light bar, so it takes the light
        // bar's own line.
        const ColoredBox(
          color: AppPalette.paperChromeLine,
          child: SizedBox(height: 1, width: double.infinity),
        ),
      ],
    );
  }
}

/// What every control here does with what the user pressed.
typedef _Apply = void Function(DocxParagraphStyle change);

/// A hairline between two groups of controls, so a row of fourteen glyphs reads
/// as five things rather than fourteen.
class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 6),
    child: ColoredBox(
      color: AppPalette.paperChromeLine,
      child: SizedBox(width: 1, height: 18),
    ),
  );
}
