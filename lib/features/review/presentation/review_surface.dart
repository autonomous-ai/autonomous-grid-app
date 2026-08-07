import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/panel_body.dart';
import '../../projects/logic/project.dart';
import '../logic/review_controller.dart';
import '../logic/review_selection.dart';
import '../logic/review_snapshot.dart';
import '../logic/review_view_prefs.dart';
import 'widgets/review_diff_view.dart';
import 'widgets/review_file_list.dart';
import 'widgets/review_states.dart';
import 'widgets/review_toolbar.dart';

/// Review: what has changed in a project's folder, and what to do about it.
///
/// Lives in a tab of the panel beside the conversation rather than on a screen
/// of its own, because reviewing is something you do *while* the assistant
/// works — walking to another screen to see what it just wrote would mean
/// leaving the chat that asked for it.
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

  /// Dismisses Review. What that means belongs to the host — today it closes
  /// the tab holding this surface, and the panel with it if it was the last.
  final VoidCallback onClose;

  /// Hands a message to the host to put in the chat's composer — how "ask the
  /// assistant to review this" reaches a conversation without this feature
  /// having to know one exists.
  final ValueChanged<String> onAskAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = project;
    if (open == null) return ReviewNoProject(onClose: onClose);

    final folder = open.path;
    final state = ref.watch(reviewProvider(folder));

    // The last answer stays on screen while a new one is fetched — changing the
    // scope re-reads the repository, and a spinner in its place would take away
    // the list you were reading to decide.
    return switch (state) {
      AsyncValue(value: final ReviewState ready) => _Body(
        state: ready,
        folder: folder,
        onClose: onClose,
        onAskAgent: onAskAgent,
      ),
      AsyncError(:final error) => ReviewFailedView(
        message: 'Grid could not read this folder: $error',
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
      onAskAgent: onAskAgent,
    ),
  };
}

/// The repository as it stands, in the panel's own geometry: the toolbar under
/// the tabs, the diff filling the pane, and the changed files beside it.
///
/// [PanelBody] owns those regions, so five features can't drift into five
/// toolbar heights. What is left to decide here is what goes in each, and that
/// depends on the room: wide enough and it is Codex's shape, with the list
/// beside the diff so picking the next file never hides the one you were
/// reading. Narrower and the two take turns, because a diff in a 200px column
/// is a column of ellipses.
class _Changes extends ConsumerWidget {
  const _Changes({
    required this.snapshot,
    required this.folder,
    required this.onAskAgent,
  });

  final ReviewSnapshot snapshot;
  final String folder;
  final ValueChanged<String> onAskAgent;

  /// Below this the panel can't hold a list and a diff side by side and still
  /// leave the diff worth reading.
  static const double _sideBySideFrom = 720;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(reviewSelectionProvider(folder));
    // A file that stopped being part of the change — staged away, undone by
    // the agent, committed — drops back to the list rather than leaving a
    // header naming a file with no diff under it.
    final file = selected == null
        ? null
        : snapshot.files.where((f) => f.path == selected).firstOrNull;

    final list = ReviewFileList(snapshot: snapshot, folder: folder);
    // Never with nothing open: hiding the list would leave the pane telling the
    // user to pick from a list that isn't there.
    final hidden = !ref.watch(reviewFilesShownProvider(folder)) && file != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide =
            constraints.maxWidth >= _sideBySideFrom && !snapshot.isEmpty;
        final toolbar = ReviewToolbar(
          snapshot: snapshot,
          folder: folder,
          onAskAgent: onAskAgent,
          canHideFiles: sideBySide && file != null,
        );
        // Nothing to review: the empty state takes the pane rather than sitting
        // in a column beside "pick a file", which would be two messages about
        // the same nothing.
        if (!sideBySide) {
          return PanelBody(
            toolbar: toolbar,
            main: file == null
                ? list
                : ReviewDiffView(file: file, folder: folder, showBack: true),
          );
        }
        return PanelBody(
          toolbar: toolbar,
          main: file == null
              ? const _NothingOpen()
              : ReviewDiffView(file: file, folder: folder, showBack: false),
          sideOpen: !hidden,
          side: list,
        );
      },
    );
  }
}

/// The wide layout with no file open yet — the diff side, waiting.
class _NothingOpen extends StatelessWidget {
  const _NothingOpen();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Pick a file to see what changed in it.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
        ),
      ),
    );
  }
}
