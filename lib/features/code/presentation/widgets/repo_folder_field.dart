import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../infrastructure/cli/git_repo.dart';
import '../../../../shared/theme/app_theme.dart';

/// Ask the user for a folder on this computer, the way Home's project dialog
/// does — one button and a line saying why.
class RepoFolderPicker extends StatelessWidget {
  const RepoFolderPicker({super.key, required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Use a folder'),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            'A shared project starts from one folder on this computer — its '
            'whole history is copied onto the grid.',
            style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
          ),
        ),
      ],
    );
  }
}

/// The chosen folder, with a way to swap it or drop it.
class RepoFolderRow extends StatelessWidget {
  const RepoFolderRow({
    super.key,
    required this.folder,
    required this.onChange,
    this.onClear,
  });

  final String folder;
  final VoidCallback onChange;

  /// Null hides the clear button — for a dialog where the folder is the whole
  /// point and stepping back would leave nothing.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
            decoration: BoxDecoration(
              color: AppPalette.cardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: AppFont.mono,
                      fontFamilyFallback: AppFont.monoFallback,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: 'Remove folder',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    color: AppPalette.textFaint,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClear,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: onChange, child: const Text('Change')),
      ],
    );
  }
}

/// What Git makes of the chosen folder, said **before** the user commits to it.
///
/// The grid can only take a repository with history: the import pushes a real
/// ref, so a folder that is not one yet — or is one with nothing committed —
/// has nothing to send. Saying which of those it is beforehand is the
/// difference between fixing it in a minute and reading a refusal from a
/// server about a folder they are looking at.
class RepoGitNote extends StatelessWidget {
  const RepoGitNote({super.key, required this.folder, required this.git});

  final String folder;

  /// What Git makes of [folder], or null while that is still being asked.
  final GitFolder? git;

  /// Whether this folder can be brought into a project at all.
  ///
  /// Unknown counts as **yes**: it means Git could not be asked, and the CLI
  /// asks git itself before it uploads anything — refusing here on a question
  /// nobody answered would block a perfectly good repository.
  static bool usable(GitFolder? git) => git is! GitUntracked;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final line = switch (git) {
      GitTracked(:final root) when root == folder =>
        'A Git repository — its history is what the grid will hold.',
      // The folder is *inside* somebody else's repository, so importing it
      // would send that whole repository, not the folder they picked.
      GitTracked(:final root) =>
        'This folder is inside the Git repository at $root, and that is what '
            'would be copied — not just this folder.',
      GitUntracked() =>
        'Not a Git repository, so there is no history to copy. Start one here '
            'and make a first commit, then come back.',
      GitFolderUnknown() || null => null,
    };
    if (line == null) return const SizedBox.shrink();

    final bad = git is GitUntracked;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            bad ? Icons.error_outline_rounded : Icons.account_tree_outlined,
            size: 15,
            color: bad
                ? Theme.of(context).colorScheme.error
                : AppPalette.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              line,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: bad
                    ? Theme.of(context).colorScheme.error
                    : AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ask the OS for a folder. One helper so both dialogs word the confirm button
/// the same way.
Future<String?> pickRepoFolder() =>
    getDirectoryPath(confirmButtonText: 'Use folder');
