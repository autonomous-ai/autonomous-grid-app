import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../logic/review_snapshot.dart';
import '../../logic/review_tree.dart';
import 'review_file_row.dart';

/// The changed files, gathered under the folder each lives in.
///
/// The filter appears once there are enough rows for scrolling to be the only
/// way to find one — below that it would be a control with nothing to do.
class ReviewFileList extends ConsumerStatefulWidget {
  const ReviewFileList({
    super.key,
    required this.snapshot,
    required this.folder,
  });

  final ReviewSnapshot snapshot;

  /// The folder being reviewed — what the rows stage against.
  final String folder;

  @override
  ConsumerState<ReviewFileList> createState() => _ReviewFileListState();
}

class _ReviewFileListState extends ConsumerState<ReviewFileList> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final files = widget.snapshot.files;
    final scope = widget.snapshot.scope;
    if (files.isEmpty) return _NothingChanged(line: scope.emptyLine);

    final shown = filterFiles(files, _query.text);
    // Ticking a file on or off only means something where there is still an
    // index to move it into — not on a branch or inside a commit.
    final stageable = scope.canStage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          // The same field the model manager searches with, so two lists in
          // the app don't ask the same question in two different shapes.
          child: TextField(
            controller: _query,
            decoration: InputDecoration(
              hintText: 'Filter files…',
              prefixIcon: const Icon(LucideIcons.search, size: 16),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppCard.insetRadius),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: AppGlass.bubbleFill,
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const EmptyState.noMatches(
                  message: 'No changed file matches that.',
                )
              : _Groups(
                  groups: groupByFolder(shown),
                  folder: widget.folder,
                  stageable: stageable,
                ),
        ),
      ],
    );
  }
}

/// The folders, each with its files under it.
class _Groups extends StatelessWidget {
  const _Groups({
    required this.groups,
    required this.folder,
    required this.stageable,
  });

  final List<ReviewGroup> groups;
  final String folder;
  final bool stageable;

  @override
  Widget build(BuildContext context) {
    // One flat list of rows and headings rather than nested scrollables: a
    // change spanning forty folders must stay lazy, and a Column of Columns
    // would build every row up front.
    final rows = <Widget>[];
    for (final group in groups) {
      rows.add(_FolderHeading(label: group.label));
      for (final file in group.files) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            // Conflicted files are *not* filtered out here: the row itself
            // shows why it can't be staged, which is the thing the user needs
            // told. Dropping the control would leave them wondering where it
            // went.
            child: ReviewFileRow(
              file: file,
              folder: folder,
              stageable: stageable,
            ),
          ),
        );
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
    );
  }
}

/// One folder's name over its files.
class _FolderHeading extends StatelessWidget {
  const _FolderHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: AppFont.medium,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}

/// Nothing to review — the good kind of empty. What *nothing* means depends on
/// the scope, so the line comes from it rather than being written here.
class _NothingChanged extends StatelessWidget {
  const _NothingChanged({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.check,
    title: 'Nothing to review',
    message: line,
    compact: true,
  );
}
