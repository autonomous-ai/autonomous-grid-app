import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A form as one plate with its questions ruled apart, rather than a run of
/// loose fields down a page.
///
/// Every route on Share Intelligence asks two or three unrelated things — which
/// model, what to call it, how much it should remember — and stacking them at
/// one level made a form with a single real decision in it look like a form with
/// six. A rule between groups says "this is a different question" in the one
/// piece of ink that cannot be mistaken for a heading.
///
/// **Lifted, not recessed.** The fields inside fill themselves [AppCard.inset];
/// a recessed plate would be that same `#F7F7F5` and they would vanish into it.
/// The rim is [AppPalette.divider], the same hairline the app rules everything
/// else with, so a plate on a white pane still has an edge (§2 — fill alone
/// cannot separate two surfaces).
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
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppGlass.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, section) in sections.indexed) ...[
            if (index > 0)
              Divider(height: 1, thickness: 1, color: AppPalette.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 17),
              child: section,
            ),
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

  /// Under this, each field would be narrower than the hint text it shows.
  static const double _stackBelow = 430;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < _stackBelow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first, const SizedBox(height: 14), second],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: first),
              const SizedBox(width: 16),
              Expanded(child: second),
            ],
          ),
  );
}
