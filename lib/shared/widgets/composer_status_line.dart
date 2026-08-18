import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One thing still running, as the composer's status strip says it.
///
/// Deliberately dumb: the feature that owns the thing builds the line and the
/// ways out of it, and the strip only decides how quiet they look.
class StatusNote {
  const StatusNote({
    required this.icon,
    required this.label,
    this.lead,
    this.actions = const [],
  });

  final IconData icon;

  /// What is running, in two or three words, set in the strip's one bit of
  /// emphasis — "Pursuing goal", "Repeating". It is the part the eye lands on;
  /// [label] beside it is the user's own wording, which is theirs and can be
  /// long. Null for a note whose whole line is already the thing.
  final String? lead;

  /// One line, in the user's terms — it shares a row with everything else that
  /// is running, so it says the thing and stops.
  final String label;

  /// What the user can do about it, in the strip's own quiet styling. Empty
  /// when the note is purely reporting.
  final List<Widget> actions;
}

/// The strip **above** the composer: what the assistant has running right now,
/// and nothing else.
///
/// It sits over the composer because that is where the thing it reports on is
/// happening — a goal is taking the turns you would otherwise be typing, and a
/// footnote under the box reads as a caption to what you are writing rather than
/// a state you are in. Codex's own goal bar sits there for the same reason.
///
/// What it kept from the version below the composer is the part that was right:
/// **one strip, not one card each.** The app used to draw a bordered box per
/// running thing — goal, loop, server — up to four at a time between the
/// transcript and the box you were typing in. Everything still running shares
/// this one surface, at most two rows plus "N more".
///
/// Anything that has *happened* — a goal met, a loop stopped — is not a status
/// and does not belong here; it is written into the conversation where it
/// happened. What is left is only ever "this is still going".
class ComposerStatusLine extends StatefulWidget {
  const ComposerStatusLine({super.key, required this.notes});

  final List<StatusNote> notes;

  @override
  State<ComposerStatusLine> createState() => _ComposerStatusLineState();
}

class _ComposerStatusLineState extends State<ComposerStatusLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    final notes = widget.notes;
    if (notes.isEmpty) return const SizedBox.shrink();
    final hidden = _open ? 0 : (notes.length - _kShown).clamp(0, notes.length);
    final shown = hidden == 0 ? notes : notes.sublist(0, _kShown);
    // Narrower than the composer and centred on it, with no gap under: the
    // strip reads as something tucked in behind the box rather than a second
    // full-width bar stacked on top of it. That inset is the whole difference
    // between "part of the composer" and "another notification".
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        widthFactor: 0.9,
        child: DecoratedBox(
          // Fill and shadow, never a rim (§0.1) — and `inset`, which is the only
          // surface token that reads in **both** themes here. Measured against
          // the page (`windowBg`) and against the composer's own fill
          // (`AppGlass.surfaceFill`):
          //
          //   token                 dark/page  light/page  dark/box  light/box
          //   AppCard.inset            1.115      1.073       1.09      1.073
          //   AppCard.base             1.188      1.000       1.023     1.000
          //   AppGlass.surfaceFill     1.215      1.000       1.000     1.000
          //
          // Both of the brighter ones are #FFFFFF in light, which is also the
          // page and also the composer: the bar would be a shadow around nothing.
          // Dark alone would never have shown it — the usual trap, running the
          // other way for once.
          decoration: BoxDecoration(
            color: AppCard.inset,
            // Rounded on top only, and to the composer's own 18 rather than the
            // card ladder's 14: the bottom edge is a seam, not an edge, and a
            // corner that curved there would leave a notch against the box below.
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final note in shown) _NoteRow(note: note),
              if (hidden > 0 || _open)
                _MoreRow(
                  hidden: hidden,
                  open: _open,
                  onTap: () => setState(() => _open = !_open),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many notes the strip shows before it folds the rest away. Two is the
/// most that ever read as a status line rather than a list.
const int _kShown = 2;

/// One line: what is running, then how to get out of it.
class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final StatusNote note;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      child: Row(
        children: [
          Icon(note.icon, size: 14, color: AppPalette.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  // The one emphasis on the strip. What is running is the fact;
                  // the user's own wording after it is the detail, and setting
                  // both the same weight is what made the old line scan as a
                  // sentence nobody finished reading.
                  if (note.lead case final lead?)
                    TextSpan(
                      text: '$lead ',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontWeight: AppFont.medium,
                      ),
                    ),
                  TextSpan(text: note.label),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
            ),
          ),
          for (final action in note.actions)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: StatusActionTheme(child: action),
            ),
        ],
      ),
    );
  }
}

/// The fold: how many are not on screen, and the way to see them.
class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.hidden,
    required this.open,
    required this.onTap,
  });

  final int hidden;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: StatusActionTheme(
      child: TextButton(
        onPressed: onTap,
        // Never a bare "more": the count is the whole point of folding, and a
        // strip that hides two servers behind a word nobody counts is the
        // stack of cards again with the numbers taken out.
        child: Text(open ? 'Show less' : '$hidden more'),
      ),
    ),
  );
}

/// One icon-sized way out of something that is running.
///
/// It owns its own hover, because nothing above it will tell it: the row does
/// not light up, and a glyph that stays dim while the pointer is on it reads as
/// decoration rather than a button. Resting at `textSecondary` and climbing to
/// `textPrimary` on a fill is the app's standard for this (`_MenuTrigger`).
class StatusIconAction extends StatefulWidget {
  const StatusIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;

  /// Required, not optional: an icon-only control with nothing to read is a
  /// guess, and these end work the user set going.
  final String tooltip;

  final VoidCallback onPressed;

  @override
  State<StatusIconAction> createState() => _StatusIconActionState();
}

class _StatusIconActionState extends State<StatusIconAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovered
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip's own button styling: the same quiet as the text beside it.
///
/// A blue link on a status line reads as the thing to do next, and none of
/// these are — they are ways to end something that is already running.
class StatusActionTheme extends StatelessWidget {
  const StatusActionTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TextButtonTheme(
    data: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppPalette.textSecondary,
        textStyle: const TextStyle(fontSize: 12, fontWeight: AppFont.medium),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    child: child,
  );
}
