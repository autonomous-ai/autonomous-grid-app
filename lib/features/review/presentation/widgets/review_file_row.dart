import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_file.dart';
import '../../logic/review_selection.dart';
import 'review_mark.dart';
import 'review_feedback.dart';

/// One changed file in the list: what happened to it, how much of it changed,
/// and whether it is going into the next commit.
///
/// The whole row opens the file's diff; only the box on the right changes what
/// Git holds. Drawn as Codex draws it — a compact row with the badge, the name,
/// the counts and one square control — rather than as a card, because a file
/// list is a list.
class ReviewFileRow extends ConsumerStatefulWidget {
  const ReviewFileRow({
    super.key,
    required this.file,
    required this.folder,
    required this.stageable,
  });

  final ReviewFile file;

  /// The folder being reviewed — the key for both the selection and the
  /// controller that stages.
  final String folder;

  /// Whether staging is on offer at all. Work already inside a commit has
  /// nothing left to tick.
  final bool stageable;

  @override
  ConsumerState<ReviewFileRow> createState() => _ReviewFileRowState();
}

class _ReviewFileRowState extends ConsumerState<ReviewFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final file = widget.file;
    final open = ref.watch(reviewSelectionProvider(widget.folder)) == file.path;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ref
            .read(reviewSelectionProvider(widget.folder).notifier)
            .open(file.path),
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            // The open file is marked by a wash, not a rim: at this row height
            // a rim reads as a text field.
            color: open
                ? AppSurface.accentWash
                : _hovered
                ? AppSurface.hoverFill
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
          child: Row(
            children: [
              ReviewMark(kind: file.kind),
              const SizedBox(width: 8),
              Expanded(
                child: _Name(file: file, open: open),
              ),
              const SizedBox(width: 6),
              ChangeCount(
                added: file.added,
                removed: file.removed,
                binary: file.binary,
              ),
              if (widget.stageable) ...[
                const SizedBox(width: 6),
                _StageBox(file: file, folder: widget.folder),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The file's name, with where it moved from after it when it moved.
class _Name extends StatelessWidget {
  const _Name({required this.file, required this.open});

  final ReviewFile file;
  final bool open;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final oldPath = file.oldPath;
    return Row(
      children: [
        Flexible(
          child: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: open ? AppFont.semibold : AppFont.regular,
              color: AppPalette.textPrimary,
              // A deleted file's name is struck through: the row is about a
              // file that isn't there any more, and the badge alone is easy to
              // miss.
              decoration: file.kind == ReviewFileKind.deleted
                  ? TextDecoration.lineThrough
                  : null,
            ),
          ),
        ),
        if (oldPath != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '← ${oldPath.split('/').last}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
            ),
          ),
        ],
      ],
    );
  }
}

/// The square that puts a file in the next commit, or takes it back out.
class _StageBox extends ConsumerStatefulWidget {
  const _StageBox({required this.file, required this.folder});

  final ReviewFile file;
  final String folder;

  @override
  ConsumerState<_StageBox> createState() => _StageBoxState();
}

class _StageBoxState extends ConsumerState<_StageBox> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final file = widget.file;
    // A half-merged file can't be staged from here: ticking it would record a
    // commit with conflict markers in it, and resolving the merge is not
    // something this surface can honestly offer.
    if (file.kind == ReviewFileKind.conflicted) {
      return Tooltip(
        message: 'Finish the merge before committing this file',
        child: Icon(
          LucideIcons.triangleAlert,
          size: 14,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }

    final staged = file.staged;
    return Tooltip(
      message: staged
          ? 'In the next commit — click to leave it out'
          : 'Include in the next commit',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: staged
                  ? AppPalette.accent
                  : _hovered
                  ? AppSurface.hoverFill
                  : AppGlass.rowFill,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              staged ? LucideIcons.minus : LucideIcons.plus,
              size: 13,
              color: staged ? Colors.white : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle() async {
    final controller = ref.read(reviewProvider(widget.folder).notifier);
    final failure = widget.file.staged
        ? await controller.unstage(widget.file)
        : await controller.stage(widget.file);
    if (failure == null || !mounted) return;
    showReviewFailure(context, failure);
  }
}
