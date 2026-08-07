import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../logic/review_file.dart';
import '../../logic/review_patch.dart';
import '../../logic/review_selection.dart';
import '../../logic/unified_diff.dart';
import 'diff_row_tile.dart';
import 'review_mark.dart';

/// One file's diff, opened from the list.
///
/// Fetched when it opens and not before — that is what lets a branch with
/// sixteen thousand changed lines appear instantly.
class ReviewDiffView extends ConsumerWidget {
  const ReviewDiffView({
    super.key,
    required this.file,
    required this.folder,
    required this.showBack,
  });

  final ReviewFile file;
  final String folder;

  /// Whether the header carries the way back to the file list.
  ///
  /// Only when the two take turns: beside a list that is on screen anyway, a
  /// back arrow points at something the user can already see.
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final patch = ref.watch(
      reviewPatchProvider((folder: folder, path: file.path)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FileHeader(file: file, folder: folder, showBack: showBack),
        const Divider(height: 1),
        Expanded(
          child: switch (patch) {
            AsyncData(value: final DiffFilePatch found) => _Patch(
              patch: found,
              file: file,
            ),
            AsyncData() => const _Unreadable(),
            AsyncError() => const _Unreadable(),
            _ => const Center(child: AppSpinner()),
          },
        ),
      ],
    );
  }
}

/// Which file this is, and the way back to the list.
class _FileHeader extends ConsumerWidget {
  const _FileHeader({
    required this.file,
    required this.folder,
    required this.showBack,
  });

  final ReviewFile file;
  final String folder;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: Row(
        children: [
          if (showBack) ...[
            AppIconButton(
              icon: LucideIcons.arrowLeft,
              size: 16,
              tooltip: 'Back to the changed files',
              onPressed: () =>
                  ref.read(reviewSelectionProvider(folder).notifier).close(),
            ),
            const SizedBox(width: 6),
          ] else
            const SizedBox(width: 6),
          ReviewMark(kind: file.kind),
          const SizedBox(width: 8),
          Expanded(child: _FileName(file: file)),
          const SizedBox(width: 8),
          ChangeCount(
            added: file.added,
            removed: file.removed,
            binary: file.binary,
          ),
        ],
      ),
    );
  }
}

/// The file's name over the folder it lives in — the name is what identifies
/// it, and a long path would push the name off the end of a narrow header.
class _FileName extends StatelessWidget {
  const _FileName({required this.file});

  final ReviewFile file;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final folder = file.folder;
    return Tooltip(
      message: file.path,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
          if (folder.isNotEmpty)
            Text(
              folder,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// The lines themselves.
class _Patch extends StatelessWidget {
  const _Patch({required this.patch, required this.file});

  final DiffFilePatch patch;
  final ReviewFile file;

  @override
  Widget build(BuildContext context) {
    if (patch.binary) return const _Binary();
    if (patch.isEmpty) return const _Unreadable();

    final language = languageForPath(file.path);
    // Flattened once here rather than nesting a list per hunk: the whole point
    // of the cap is that one lazy list draws only the rows on screen.
    final rows = <Widget>[];
    for (final hunk in patch.hunks) {
      rows.add(_HunkHeading(hunk: hunk));
      for (final row in hunk.rows) {
        rows.add(DiffRowTile(row: row, language: language));
      }
    }
    if (patch.truncatedBy > 0) {
      rows.add(_Truncated(lines: patch.truncatedBy));
    }

    return CodeTextScope(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: rows.length,
        itemBuilder: (context, i) => rows[i],
      ),
    );
  }
}

/// Where in the file the next run of lines is.
class _HunkHeading extends StatelessWidget {
  const _HunkHeading({required this.hunk});

  final DiffHunk hunk;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final where = hunk.context;
    return Container(
      width: double.infinity,
      color: AppGlass.rowFill,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        where.isEmpty ? _lineRange(hunk.header) : where,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppFont.codeStyle(color: AppPalette.textSecondary, scale: 0.9),
      ),
    );
  }

  /// `@@ -12,7 +12,9 @@` with the fences dropped — still precise, but not
  /// shouting punctuation at someone who has never read a diff.
  String _lineRange(String header) =>
      header.replaceAll('@@', '').trim().replaceAll('  ', ' ');
}

/// The tail of a file too long to draw. Said out loud, never silently cut (§9).
class _Truncated extends StatelessWidget {
  const _Truncated({required this.lines});

  final int lines;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      child: Text(
        '$lines more changed lines are not shown here — this file is too long '
        'to draw in full. Open it in your editor to read the rest.',
        style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
      ),
    );
  }
}

/// A file whose contents aren't text.
class _Binary extends StatelessWidget {
  const _Binary();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: LucideIcons.fileImage,
    title: 'Not a text file',
    message: "Git can tell this file changed, but there are no lines to show.",
    compact: true,
  );
}

/// Git couldn't produce this file's diff.
class _Unreadable extends StatelessWidget {
  const _Unreadable();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: LucideIcons.fileQuestion,
    title: "Couldn't show this change",
    message:
        'Git did not return a diff for this file. It may have changed again '
        'while you were looking at it — try refreshing.',
    compact: true,
  );
}
