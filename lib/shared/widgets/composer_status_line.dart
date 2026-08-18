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
    this.actions = const [],
  });

  final IconData icon;

  /// One line, in the user's terms — it shares a row with everything else that
  /// is running, so it says the thing and stops.
  final String label;

  /// What the user can do about it, in the strip's own quiet styling. Empty
  /// when the note is purely reporting.
  final List<Widget> actions;
}

/// The dim strip under the composer: what the assistant has running right now,
/// and nothing else.
///
/// It replaced a stack of bordered cards above the composer — a goal, a loop, a
/// server, each in its own boxed row with its own blue buttons, up to four of
/// them at once between the transcript and the thing the user was typing in.
/// Claude Code and Codex both put this on one quiet line and keep the news
/// itself in the transcript, and that is what this is: no card, no shadow, no
/// accent, just the state and the way out of it.
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
    return Padding(
      padding: const EdgeInsets.only(top: 6),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    child: Row(
      children: [
        Icon(note.icon, size: 13, color: AppPalette.textFaint),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            note.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
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
