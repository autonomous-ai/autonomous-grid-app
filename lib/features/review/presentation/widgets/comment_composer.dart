import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/review_comment.dart';
import '../../logic/review_comments_controller.dart';

/// The box that opens under a line of the diff to ask for a change to it.
///
/// Named "Local comment" out loud: it goes nowhere but this window and the next
/// message to the assistant, and a box that looked like a review comment would
/// have people waiting for a teammate who is never coming.
class CommentComposer extends ConsumerStatefulWidget {
  const CommentComposer({super.key, required this.draft, required this.folder});

  final CommentDraft draft;

  /// The folder being reviewed — where the comment is kept.
  final String folder;

  @override
  ConsumerState<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends ConsumerState<CommentComposer> {
  late final TextEditingController _text = TextEditingController(
    text: widget.draft.text,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final draft = widget.draft;
    final ready = _text.text.trim().isNotEmpty;

    return CommentSurface(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
            if (ready) _save();
          },
          const SingleActivator(LogicalKeyboardKey.escape): _close,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CommentHeading(
              anchor: '${draft.side.mark}${draft.line}',
              trailing: null,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
              decoration: InputDecoration(
                hintText: 'Ask for a change to this line',
                hintStyle: TextStyle(fontSize: 13, color: AppPalette.textFaint),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _close,
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.textSecondary,
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: ready ? _save : null,
                  child: const Text('Comment'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    ref
        .read(reviewCommentsProvider(widget.folder).notifier)
        .add(widget.draft.toComment(_text.text));
    _close();
  }

  void _close() =>
      ref.read(reviewCommentDraftProvider(widget.folder).notifier).close();
}

/// A comment already left, sitting under its line until it is sent or taken
/// back.
class CommentCard extends ConsumerWidget {
  const CommentCard({super.key, required this.comment, required this.folder});

  final ReviewComment comment;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return CommentSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommentHeading(
            anchor: comment.anchor,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Quiet(
                  icon: LucideIcons.pencil,
                  tooltip: 'Rewrite this comment',
                  onPressed: () => ref
                      .read(reviewCommentDraftProvider(folder).notifier)
                      .open(
                        CommentDraft(
                          path: comment.path,
                          side: comment.side,
                          line: comment.line,
                          code: comment.code,
                          text: comment.text,
                        ),
                      ),
                ),
                _Quiet(
                  icon: LucideIcons.trash2,
                  tooltip: 'Take this comment back',
                  onPressed: () => ref
                      .read(reviewCommentsProvider(folder).notifier)
                      .remove(comment),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            comment.text,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// What both boxes sit on: inset from the diff so it reads as *about* the line
/// above rather than as another line of it.
class CommentSurface extends StatelessWidget {
  const CommentSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppGlass.hair),
        ),
        child: child,
      ),
    );
  }
}

/// "Local comment · on line R32", and whatever the card wants at the end.
class CommentHeading extends StatelessWidget {
  const CommentHeading({super.key, required this.anchor, this.trailing});

  final String anchor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Icon(LucideIcons.messageSquare, size: 13, color: AppPalette.textFaint),
        const SizedBox(width: 6),
        Text(
          'Local comment',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
          ),
        ),
        const Spacer(),
        if (trailing == null)
          Text(
            'on line $anchor',
            style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
          )
        else
          trailing!,
      ],
    );
  }
}

/// A small icon action inside a comment card.
class _Quiet extends StatelessWidget {
  const _Quiet({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return IconButton(
      icon: Icon(icon, size: 13),
      tooltip: tooltip,
      onPressed: onPressed,
      color: AppPalette.textFaint,
      hoverColor: AppSurface.hoverFill,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      visualDensity: VisualDensity.compact,
    );
  }
}
