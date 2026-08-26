import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../features/provider_node/presentation/engine_block.dart';
import 'app_spinner.dart';
import 'meta_label.dart';

/// What pressing a [ChoiceRow] does, so the mark on its right can tell the
/// truth about it.
enum ChoiceRowAction {
  /// Reveals the row's own form underneath it — a chevron that turns to point
  /// down at what it opened.
  open,

  /// Hands off to somewhere that isn't this window (the browser, for a sign-in)
  /// — an arrow leading out.
  leave,
}

/// One way to do a thing, worn as a row you press: an icon, a title, one line,
/// and a mark saying what pressing it does.
///
/// This replaced a card that spent a title, a line and a *button* on each option
/// — and the button mostly repeated the title ("Use an API key" → Enter a key).
/// Four of them stacked ran past the fold, all four at identical weight, with the
/// real target a small button inside each. As a row the whole strip is the
/// target, the button goes, and the same four options cost a third of the height.
///
/// Shared between the first-run screen and the Model Engines tab on purpose:
/// they offer the *same* ways onto a grid, and a user who picked one on the way
/// in should meet it wearing the same clothes later.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    this.line,
    required this.action,
    required this.onPressed,
    this.badge,
    this.busy = false,
    this.expanded = false,
    this.child,
  });

  /// A widget, not an `IconData`, so a row that hands an account to a vendor
  /// can carry that vendor's own mark where our glyph would sit.
  final Widget icon;

  final String title;

  /// The one line under the title, or null for a row whose title already
  /// says the whole thing.
  ///
  /// One line, not a paragraph — the detail belongs in what the row opens,
  /// not in front of it. Dropping it entirely is for a row sitting in a list
  /// of single-line items, where a second line would make the action look
  /// like a heavier kind of thing than the rows it stands beside.
  final String? line;

  /// Two or three words naming what this option *saves* the user — "no setup",
  /// "private & offline". A benefit, never a restatement of the title: it earns
  /// its place only by answering "why this one?" at a glance.
  final String? badge;

  /// The press is under way — the row waits instead of taking another. Only
  /// worth setting where the screen stays put while it works; a page that leaves
  /// the moment a press lands has nothing to show a spinner to.
  final bool busy;

  final ChoiceRowAction action;
  final VoidCallback onPressed;

  /// Whether [child] is showing, so the chevron matches what the user sees.
  final bool expanded;

  /// The form this row reveals, or null while it has nothing open.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette/AppSurface — follow theme flips
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: busy ? null : onPressed,
          // No ripple: a macOS row answers a click with an instant state
          // change, so the hover tint carries the whole affordance (as in the
          // chat composer's buttons).
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppSurface.hoverFill,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(15, 11, 13, 11),
            child: Row(
              children: [
                // The slot dresses the glyph, so a caller passes a bare `Icon`
                // and gets the row's own size and tone. A vendor's mark brings
                // its own colours and simply ignores this.
                SizedBox(
                  width: 20,
                  child: Center(
                    child: IconTheme.merge(
                      data: IconThemeData(
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      child: icon,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      if (line case final line?) ...[
                        const SizedBox(height: 2),
                        Text(
                          line,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 10),
                  MetaLabel(badge!),
                ],
                const SizedBox(width: 10),
                if (busy)
                  const SizedBox(
                    width: 19,
                    height: 19,
                    child: Center(child: AppSpinner(size: SpinnerSize.small)),
                  )
                else
                  _Marker(action: action, expanded: expanded),
              ],
            ),
          ),
        ),
        ?child,
      ],
    );
  }
}

/// The mark on the row's right: a chevron that turns as the row opens, or an
/// arrow leading out for a row that hands off to the browser.
class _Marker extends StatelessWidget {
  const _Marker({required this.action, required this.expanded});

  final ChoiceRowAction action;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (action == ChoiceRowAction.leave) {
      return Icon(
        Icons.arrow_outward_rounded,
        size: 17,
        color: AppPalette.textFaint,
      );
    }
    // A quarter turn, at the app's hover speed: the chevron ends up pointing at
    // what it opened, so the row still reads correctly after the animation as
    // well as during it.
    return AnimatedRotation(
      turns: expanded ? 0.25 : 0,
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      child: Icon(
        Icons.chevron_right_rounded,
        size: 19,
        color: AppPalette.textFaint,
      ),
    );
  }
}

/// [ChoiceRow]s as one surface, hairline-separated — a single object holding
/// every way to do the thing, rather than four cards the eye has to gather.
///
/// The divider follows each row's *opened* form rather than the row itself, so
/// an expanded option stays visibly one piece with what it opened.
class ChoiceRowGroup extends StatelessWidget {
  const ChoiceRowGroup({
    super.key,
    required this.children,
    this.outlined = false,
  });

  /// One [ChoiceRow] each — or the stateful widget that builds one, which is
  /// why this can't be typed tighter: a row that remembers whether it's open
  /// owns that state itself.
  final List<Widget> children;

  /// Wear a visible rim instead of the usual white-and-a-whisper-of-shadow.
  ///
  /// Set it on a **white ground** — the onboarding card — where the standard
  /// surface is invisible: its fill is the same white it sits on and the shadow
  /// alone doesn't carry the edge, so the group renders as bare text with
  /// nothing to press. On the tabs, which sit on a tinted pane, the default is
  /// right.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(EngineSurface.radius);
    // The rows bring their own padding — the surface supplies only the fill, so
    // a hover tint reaches the full width of the row.
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, row) in children.indexed) ...[
          row,
          if (index != children.length - 1)
            Divider(height: 1, thickness: 1, color: AppPalette.divider),
        ],
      ],
    );

    if (!outlined) {
      return ClipRRect(
        borderRadius: radius,
        child: EngineSurface(padding: EdgeInsets.zero, child: rows),
      );
    }
    return DecoratedBox(
      // In the foreground, so a row's hover fill runs under the rim rather than
      // painting over it.
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: AppGlass.lift),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(color: AppGlass.surfaceFill, child: rows),
      ),
    );
  }
}
