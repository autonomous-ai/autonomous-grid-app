import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../infrastructure/cli/git_providers.dart';
import '../../../../shared/layouts/shell_state.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/review_controller.dart';

/// No project is open, so there is no folder to review.
///
/// Not a failure — the ordinary state of a chat that isn't about code. It says
/// what a project is for rather than only that one is missing.
class ReviewNoProject extends StatelessWidget {
  const ReviewNoProject({super.key, required this.onClose});

  /// Dismisses Review. Offered here because this is the one state the surface
  /// can do nothing from: with no project there is no folder to look at, and a
  /// tab that can only be shut from its own strip is a dead end (§5).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.folderOpen,
    title: 'Open a chat in a project',
    message:
        'Review shows what changed in a project folder. Start a chat inside '
        'one and the changes appear here.',
    compact: true,
    action: TextButton(onPressed: onClose, child: const Text('Close Review')),
  );
}

/// This computer has no Git for the app to run.
class ReviewNeedsGitView extends ConsumerWidget {
  const ReviewNeedsGitView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
    icon: LucideIcons.gitBranch,
    title: 'Grid needs Git for this',
    message:
        'Reviewing changes means asking Git what changed, and this computer '
        "doesn't have one Grid can use yet.",
    compact: true,
    action: FilledButton(
      onPressed: () =>
          ref.read(shellSectionProvider.notifier).select(ShellSection.git),
      child: const Text('Set up Git'),
    ),
  );
}

/// The folder isn't in a repository, so nothing is tracking its changes.
class ReviewNotARepoView extends ConsumerStatefulWidget {
  const ReviewNotARepoView({
    super.key,
    required this.folder,
    required this.reviewFolder,
  });

  /// The folder Git found nothing above.
  final String folder;

  /// The key the surface is reading — what to re-read once a repository
  /// exists.
  final String reviewFolder;

  @override
  ConsumerState<ReviewNotARepoView> createState() => _ReviewNotARepoViewState();
}

class _ReviewNotARepoViewState extends ConsumerState<ReviewNotARepoView> {
  bool _starting = false;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.folderGit2,
    title: 'This folder has no history yet',
    message:
        'Git is what remembers every version of a file. Start it here and '
        "you'll be able to see what changed, and undo anything.",
    compact: true,
    action: FilledButton(
      onPressed: _starting ? null : _start,
      child: const Text('Start tracking changes'),
    ),
  );

  Future<void> _start() async {
    setState(() => _starting = true);
    // The same call the project dialog makes, so a folder started from either
    // place ends up in exactly the same shape.
    final failure = await ref.read(gitRepoServiceProvider).init(widget.folder);
    if (!mounted) return;
    setState(() => _starting = false);
    if (failure != null) {
      ToastScope.show(
        context,
        ToastSpec(message: failure, severity: ToastSeverity.error),
      );
      return;
    }
    await ref.read(reviewProvider(widget.reviewFolder).notifier).refresh();
  }
}

/// Git ran and refused. The message is already in the user's terms; the raw
/// text went to the log.
class ReviewFailedView extends ConsumerWidget {
  const ReviewFailedView({
    super.key,
    required this.message,
    required this.folder,
  });

  final String message;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
    icon: LucideIcons.circleAlert,
    title: "Couldn't read this folder",
    message: message,
    compact: true,
    action: FilledButton(
      onPressed: () => ref.read(reviewProvider(folder).notifier).refresh(),
      child: const Text('Try again'),
    ),
  );
}
