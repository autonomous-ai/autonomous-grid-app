import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../projects/logic/project.dart';
import '../logic/review_controller.dart';
import '../logic/review_selection.dart';
import '../logic/review_snapshot.dart';
import 'widgets/review_diff_view.dart';
import 'widgets/review_file_list.dart';
import 'widgets/review_header.dart';
import 'widgets/review_states.dart';

/// Review: what has changed in a project's folder, and what to do about it.
///
/// Lives in the panel beside the conversation rather than on a screen of its
/// own, because reviewing is something you do *while* the assistant works —
/// walking to another screen to see what it just wrote would mean leaving the
/// chat that asked for it.
///
/// The panel is 420–760px wide, so the file list and a file's diff take turns
/// rather than sitting side by side: at that width a two-column diff would be
/// two columns of ellipses.
class ReviewSurface extends ConsumerWidget {
  const ReviewSurface({
    super.key,
    required this.project,
    required this.onClose,
    required this.onAskAgent,
  });

  /// The project whose folder is under review — the open chat's, or null when
  /// the chat belongs to no project.
  final Project? project;

  /// Leaves Review and puts the panel back to what it can open.
  final VoidCallback onClose;

  /// Hands a message to the host to put in the chat's composer — how "ask the
  /// assistant to review this" reaches a conversation without this feature
  /// having to know one exists.
  final ValueChanged<String> onAskAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = project;
    if (open == null) return const ReviewNoProject();

    final folder = open.path;
    final state = ref.watch(reviewProvider(folder));

    return switch (state) {
      AsyncData(:final value) => _Body(
        state: value,
        folder: folder,
        onClose: onClose,
        onAskAgent: onAskAgent,
      ),
      AsyncError(:final error) => ReviewFailedView(
        message: '$error',
        folder: folder,
      ),
      _ => const Center(child: AppSpinner(size: SpinnerSize.large)),
    };
  }
}

/// What the repository turned out to be.
class _Body extends ConsumerWidget {
  const _Body({
    required this.state,
    required this.folder,
    required this.onClose,
    required this.onAskAgent,
  });

  final ReviewState state;
  final String folder;
  final VoidCallback onClose;
  final ValueChanged<String> onAskAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) => switch (state) {
    ReviewNeedsGit() => const ReviewNeedsGitView(),
    ReviewNotARepo(:final folder) => ReviewNotARepoView(
      folder: folder,
      reviewFolder: this.folder,
    ),
    ReviewFailed(:final message) => ReviewFailedView(
      message: message,
      folder: folder,
    ),
    ReviewReady(:final snapshot) => _Changes(
      snapshot: snapshot,
      folder: folder,
      onClose: onClose,
      onAskAgent: onAskAgent,
    ),
  };
}

/// The repository as it stands: the header, and either the list or the file
/// the user opened from it.
class _Changes extends ConsumerWidget {
  const _Changes({
    required this.snapshot,
    required this.folder,
    required this.onClose,
    required this.onAskAgent,
  });

  final ReviewSnapshot snapshot;
  final String folder;
  final VoidCallback onClose;
  final ValueChanged<String> onAskAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(reviewSelectionProvider(folder));
    // A file that stopped being part of the change — staged away, undone by
    // the agent, committed — drops back to the list rather than leaving a
    // header naming a file with no diff under it.
    final file = selected == null
        ? null
        : snapshot.files.where((f) => f.path == selected).firstOrNull;

    if (file != null) return ReviewDiffView(file: file, folder: folder);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReviewHeader(
          snapshot: snapshot,
          folder: folder,
          onClose: onClose,
          onAskAgent: onAskAgent,
        ),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Expanded(
          child: ReviewFileList(snapshot: snapshot, folder: folder),
        ),
      ],
    );
  }
}
