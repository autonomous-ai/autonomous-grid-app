import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/git_providers.dart';
import '../../../infrastructure/cli/git_repo.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'git_failure.dart';
import 'review_actions.dart';
import 'review_base.dart';
import 'review_failure.dart';
import 'review_file.dart';
import 'review_loader.dart';
import 'review_snapshot.dart';

/// What the Review surface has to show for a folder.
///
/// Four outcomes rather than a snapshot-or-error pair, because three of them
/// are things the user can *do* something about and each leads somewhere
/// different: install Git, start a repository here, or read what Git said.
sealed class ReviewState {
  const ReviewState();
}

/// This computer has no Git the app can run. The surface points at the Git
/// screen, which is where that gets fixed.
class ReviewNeedsGit extends ReviewState {
  const ReviewNeedsGit();
}

/// The folder isn't inside a repository, so there is nothing to compare
/// against. The surface offers to start one.
class ReviewNotARepo extends ReviewState {
  const ReviewNotARepo(this.folder);
  final String folder;
}

/// Git ran and refused. [message] is the humanised line; the raw text is
/// already in the log.
class ReviewFailed extends ReviewState {
  const ReviewFailed(this.message);
  final String message;
}

/// The repository as it stands.
class ReviewReady extends ReviewState {
  const ReviewReady(this.snapshot);
  final ReviewSnapshot snapshot;
}

/// Which comparison the surface is showing for one folder.
///
/// Per folder rather than one setting for the whole app: `origin/main` is a
/// branch that exists in one repository and not the next, so a base carried
/// across projects would resolve to nothing.
final reviewBaseProvider =
    NotifierProvider.family<ReviewBaseController, ReviewBase, String>(
      ReviewBaseController.new,
    );

class ReviewBaseController extends Notifier<ReviewBase> {
  ReviewBaseController(this.folder);

  /// The folder this choice belongs to — the family argument, which is what
  /// keeps one repository's base out of another's.
  final String folder;

  @override
  ReviewBase build() => const UncommittedChanges();

  void show(ReviewBase base) => state = base;
}

/// The changes in one folder, for whichever comparison [reviewBaseProvider]
/// holds for it.
///
/// Keyed by the folder rather than reading "the current project" from
/// somewhere: the surface is handed the project it belongs to, and a second
/// place asking about a different folder gets its own answer instead of
/// fighting over one.
final reviewProvider =
    AsyncNotifierProvider.family<ReviewController, ReviewState, String>(
      ReviewController.new,
    );

class ReviewController extends AsyncNotifier<ReviewState> {
  ReviewController(this._folder);

  /// The folder the user picked — which may be *inside* a repository rather
  /// than its root.
  final String _folder;

  @override
  Future<ReviewState> build() {
    // Changing the comparison re-reads the repository; that's the whole
    // mechanism behind the base picker.
    ref.watch(reviewBaseProvider(_folder));
    return _read();
  }

  /// Read the repository again — after an edit the agent made, after staging,
  /// or because the user asked.
  ///
  /// The list on screen stays put while this runs rather than falling back to a
  /// spinner: a refresh that blanks the file you were reading loses your place
  /// every time an agent touches a file.
  Future<void> refresh() async => state = AsyncData(await _read());

  /// Include [file] in the next commit. Returns null when it worked, else a
  /// line to show; the list is re-read either way, so what's on screen matches
  /// what Git now holds.
  Future<String?> stage(ReviewFile file) =>
      _act((actions, root) => actions.stage(root, file), 'stage ${file.path}');

  /// Leave [file] out of it again.
  Future<String?> unstage(ReviewFile file) => _act((actions, root) {
    final ready = state.value;
    final hasCommits = ready is ReviewReady ? ready.snapshot.hasCommits : true;
    return actions.unstage(root, file, hasCommits: hasCommits);
  }, 'unstage ${file.path}');

  /// Include everything that changed.
  Future<String?> stageAll() =>
      _act((actions, root) => actions.stageAll(root), 'stage everything');

  /// Run one write against the repository root, then re-read.
  Future<String?> _act(
    Future<ReviewFailure?> Function(ReviewActions actions, String root) write,
    String what,
  ) async {
    final ready = state.value;
    if (ready is! ReviewReady) return null;
    final failure = await write(
      ref.read(reviewActionsProvider),
      ready.snapshot.root,
    );
    await refresh();
    return _explain(failure, what);
  }

  Future<ReviewState> _read() async {
    final folder = await ref.read(gitRepoServiceProvider).inspect(_folder);
    return switch (folder) {
      GitFolderUnknown() => const ReviewNeedsGit(),
      GitUntracked() => ReviewNotARepo(_folder),
      GitTracked(:final root) => await _readRepo(root),
    };
  }

  Future<ReviewState> _readRepo(String root) async {
    final base = ref.read(reviewBaseProvider(_folder));
    final (snapshot, failure) = await ref
        .read(reviewLoaderProvider)
        .load(root, base);
    if (snapshot != null) return ReviewReady(snapshot);
    final message = _explain(failure, 'read $root');
    return message == null ? const ReviewNeedsGit() : ReviewFailed(message);
  }

  /// The sentence for [failure], with Git's own words logged beside it. Null
  /// when nothing went wrong.
  String? _explain(ReviewFailure? failure, String what) {
    if (failure == null) return null;
    final ready = state.value;
    final snapshot = ready is ReviewReady ? ready.snapshot : null;
    return explainReviewFailure(
      failure,
      log: ref.read(appLogProvider),
      what: what,
      branch: snapshot?.branch,
      remote: snapshot?.upstream?.split('/').first,
    );
  }
}

/// Reads a repository into a snapshot.
final reviewLoaderProvider = Provider<ReviewLoader>(
  (ref) => ReviewLoader(ref.watch(gitRunnerProvider)),
);

/// The commands that change something in a repository, plus a single file's
/// diff.
final reviewActionsProvider = Provider<ReviewActions>(
  (ref) => ReviewActions(ref.watch(gitRunnerProvider)),
);
