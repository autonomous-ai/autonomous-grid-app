import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/share_page_theme.dart';

/// A form as one plate with its questions ruled apart, rather than a run of
/// loose fields down a page.
///
/// Every route on Share Intelligence asks two or three unrelated things — which
/// model, what to call it, how much it should remember — and stacking them at
/// one level made a form with a single real decision in it look like a form with
/// six. A rule between groups says "this is a different question" in the one
/// piece of ink that cannot be mistaken for a heading.
///
/// Its two greys are a pair on purpose and come from the design: the rim is
/// [SharePalette.rim], the rules inside are [SharePalette.innerRule], one shade
/// lighter — so the plate reads as one object with divisions rather than as
/// three cards stacked flush.
class FormPlate extends StatelessWidget {
  const FormPlate({super.key, required this.sections});

  /// One group of related fields each. A rule is drawn between them, never
  /// above the first or below the last.
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      decoration: BoxDecoration(
        color: SharePalette.surface,
        borderRadius: BorderRadius.circular(ShareMetrics.plateRadius),
        border: Border.all(color: SharePalette.rim),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, section) in sections.indexed) ...[
            if (index > 0)
              Divider(height: 1, thickness: 1, color: SharePalette.innerRule),
            Padding(padding: ShareMetrics.plateSection, child: section),
          ],
        ],
      ),
    );
  }
}

/// Two fields side by side, stacked instead when the pane is too narrow to give
/// each one room to be read.
///
/// The pair is a pair because the two questions are the same kind — what the
/// grid calls this model, and what it calls this computer. Desktop windows get
/// dragged small (§4), and two inputs sharing 300px is worse than two rows.
class FieldPair extends StatelessWidget {
  const FieldPair({super.key, required this.first, required this.second});

  final Widget first;
  final Widget second;

  /// The design's own column gap.
  static const double _gap = 16;

  /// Under this, each field would be narrower than the hint text it shows.
  static const double _stackBelow = 430;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < _stackBelow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: _gap),
              second,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: first),
              const SizedBox(width: _gap),
              Expanded(child: second),
            ],
          ),
  );
}
