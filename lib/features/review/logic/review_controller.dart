import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/git_providers.dart';
import '../../../infrastructure/cli/git_repo.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/file_changes.dart';
import 'git_failure.dart';
import 'review_actions.dart';
import 'review_scope.dart';
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

/// The files the assistant touched in its most recent turn, absolute paths.
///
/// Pushed in by whoever hosts the surface rather than read from the agent
/// feature directly: which assistant, in which conversation, is the chat's
/// business, and Review's job is only to narrow a file list by it.
final reviewLastTurnPathsProvider =
    NotifierProvider<ReviewLastTurnPaths, Set<String>>(ReviewLastTurnPaths.new);

class ReviewLastTurnPaths extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// What the assistant has just changed. A no-op when it is what we already
  /// hold — the chat republishes on every rebuild, and each real change re-reads
  /// the repository.
  void show(Set<String> paths) {
    if (paths.length == state.length && paths.every(state.contains)) return;
    state = Set.unmodifiable(paths);
  }
}

/// Which comparison the surface is showing for one folder.
///
/// Per folder rather than one setting for the whole app: `origin/main` is a
/// branch that exists in one repository and not the next, so a scope carried
/// across projects would resolve to nothing.
final reviewScopeProvider =
    NotifierProvider.family<ReviewScopeController, ReviewScope, String>(
      ReviewScopeController.new,
    );

class ReviewScopeController extends Notifier<ReviewScope> {
  ReviewScopeController(this.folder);

  /// The folder this choice belongs to — the family argument, which is what
  /// keeps one repository's scope out of another's.
  final String folder;

  @override
  ReviewScope build() => const UncommittedChanges();

  void show(ReviewScope base) => state = base;
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

/// How long the writing has to stop before Review re-reads the repository.
///
/// Longer than the file panel's own settling time, and deliberately so: one read
/// here is around eight `git` processes, where reading a file is one call into
/// the filesystem. Long enough that a build or a checkout is one read; short
/// enough that a saved file shows up while the user is still looking at it.
const _diskSettle = Duration(milliseconds: 400);

class ReviewController extends AsyncNotifier<ReviewState> {
  ReviewController(this._folder);

  /// The folder the user picked — which may be *inside* a repository rather
  /// than its root.
  final String _folder;

  /// The pending re-read, waiting for the writing to stop. See [_diskSettle].
  Timer? _settle;

  /// Which read is the current one. A read that finishes after a later one
  /// started is history, and must not be allowed to put its older snapshot on
  /// screen — staging a file and having the list flick back to unstaged is what
  /// that looks like.
  int _reads = 0;

  @override
  Future<ReviewState> build() {
    // Changing the comparison re-reads the repository; that's the whole
    // mechanism behind the scope menu.
    final scope = ref.watch(reviewScopeProvider(_folder));
    // The set of paths the "Last turn" scope narrows by is part of what that
    // scope *is*, so it re-reads on every change to it. Every other scope
    // follows the disk instead — see [_followDisk].
    if (scope is LastTurnChanges) ref.watch(reviewLastTurnPathsProvider);
    _followDisk();
    return _read();
  }

  /// Re-read after something writes inside this folder, once the writing stops.
  ///
  /// Watching every single write was tried and taken out again: it meant around
  /// eight `git` invocations *per file the agent saved*, a storm of process
  /// spawns behind a list nobody was necessarily looking at. What makes it
  /// affordable now is that the announcement is already gathered into bursts
  /// ([fileChangesProvider]) and this waits out the rest of the burst on top of
  /// it — an agent rewriting twelve files costs one read, not twelve.
  ///
  /// Without it the panel is honest only at the moment it opens: the default
  /// scope is [UncommittedChanges], and the whole point of Review sitting beside
  /// the conversation is watching the diff grow as the assistant works.
  void _followDisk() {
    ref.onDispose(() => _settle?.cancel());
    ref.listen(fileChangesProvider, (_, notice) {
      if (!notice.paths.any(_isInFolder)) return;
      _settle?.cancel();
      _settle = Timer(_diskSettle, _reread);
    });
  }

  /// [refresh], with the failure handling a background read needs and a
  /// foreground one doesn't.
  ///
  /// Nobody is waiting on this one, so a throw from it has nowhere to go but out
  /// of the timer and into the zone — and this fires whenever the assistant
  /// writes, which is exactly the shape that fills a log file with the same
  /// stack trace a thousand times. The screen keeps the snapshot it had, which
  /// is what a failed read leaves behind anyway.
  Future<void> _reread() async {
    try {
      await refresh();
    } on Object catch (error, stackTrace) {
      if (!ref.mounted) return;
      ref
          .read(appLogProvider)
          .failure(
            'review',
            're-reading $_folder after a write failed',
            error: error,
            stackTrace: stackTrace,
          );
    }
  }

  /// Whether [path] is this folder or something under it.
  ///
  /// The separator matters: without it `/w/grid` would claim every write in
  /// `/w/grid-app` next door and re-read this repository for changes that have
  /// nothing to do with it.
  bool _isInFolder(String path) =>
      path == _folder ||
      path.startsWith('$_folder/') ||
      path.startsWith('$_folder\\');

  /// Read the repository again — after an edit the agent made, after staging,
  /// or because the user asked.
  ///
  /// The list on screen stays put while this runs rather than falling back to a
  /// spinner: a refresh that blanks the file you were reading loses your place
  /// every time an agent touches a file.
  Future<void> refresh() async {
    // Reading touches half a dozen providers, so a surface that has already gone
    // must not start one — the timer behind [_followDisk] is cancelled on the
    // way out, but a click that lands on the closing frame is not.
    if (!ref.mounted) return;
    final read = ++_reads;
    final next = await _read();
    // Git is slow enough to be overtaken, and the surface can be gone by the
    // time it answers — a tab closed mid-read, a project switched away from.
    if (read != _reads || !ref.mounted) return;
    state = AsyncData(next);
  }

  /// Include [file] in the next commit. Returns null when it worked, else a
  /// line to show; the list is re-read either way, so what's on screen matches
  /// what Git now holds.
  Future<String?> stage(ReviewFile file) => _act(
    (actions, repo) => actions.stage(repo.root, file),
    'stage ${file.path}',
  );

  /// Leave [file] out of it again.
  Future<String?> unstage(ReviewFile file) => _act(
    (actions, repo) =>
        actions.unstage(repo.root, file, hasCommits: repo.hasCommits),
    'unstage ${file.path}',
  );

  /// Include every file the list is showing.
  Future<String?> stageAll() => _act(
    (actions, repo) => actions.stageAll(repo.root, repo.files),
    'stage everything',
  );

  /// Run one write against the repository as it was last read, then re-read.
  ///
  /// The snapshot rather than just its root: staging and unstaging both need
  /// something else off it, and reaching back into `state` mid-action was how
  /// one of them ended up reading the repository twice.
  Future<String?> _act(
    Future<ReviewFailure?> Function(ReviewActions actions, ReviewSnapshot repo)
    write,
    String what,
  ) async {
    final ready = state.value;
    if (ready is! ReviewReady) return null;
    final failure = await write(
      ref.read(reviewActionsProvider),
      ready.snapshot,
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
    final (snapshot, failure) = await ref
        .read(reviewLoaderProvider)
        .load(
          root,
          ref.read(reviewScopeProvider(_folder)),
          lastTurnPaths: ref.read(reviewLastTurnPathsProvider),
        );
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
