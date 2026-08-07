import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import 'git_failure.dart';
import 'review_controller.dart';
import 'review_failure.dart';
import 'review_snapshot.dart';

/// Where a commit (and the push that may follow it) has got to.
sealed class CommitState {
  const CommitState();
}

/// Nothing in flight.
class CommitIdle extends CommitState {
  const CommitIdle();
}

/// Working. [step] is what's happening now, in the user's words — the two
/// halves take very different amounts of time, and "Pushing…" after a commit
/// that already succeeded is the difference between a hang and progress.
class CommitRunning extends CommitState {
  const CommitRunning(this.step);
  final String step;
}

/// It didn't finish. [message] is what to show; [committed] says whether the
/// commit itself was made before the failure — a push that fails after a
/// successful commit must not read as "nothing happened", or the user commits
/// the same work twice.
class CommitFailed extends CommitState {
  const CommitFailed(this.message, {this.committed = false});
  final String message;
  final bool committed;
}

/// Done. [pushed] is false when the user only committed.
class CommitDone extends CommitState {
  const CommitDone({required this.pushed, required this.branch});
  final bool pushed;
  final String branch;
}

/// Committing what's staged in one folder, and optionally sending it on.
final commitProvider =
    NotifierProvider.family<CommitController, CommitState, String>(
      CommitController.new,
    );

class CommitController extends Notifier<CommitState> {
  CommitController(this.folder);

  /// The folder whose repository this commits — the family argument.
  final String folder;

  @override
  CommitState build() => const CommitIdle();

  /// Record the staged changes as a commit, and send the branch to its remote
  /// when [push] is set.
  ///
  /// The two are one action from the user's side ("commit and push") but two
  /// commands, and the second can fail on its own — which is why [CommitFailed]
  /// carries whether the commit was made.
  Future<void> run({required String message, required bool push}) async {
    if (state is CommitRunning) return;
    final snapshot = _snapshot();
    if (snapshot == null) return;

    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      state = const CommitFailed('Say what this change does first.');
      return;
    }

    state = const CommitRunning('Committing…');
    final actions = ref.read(reviewActionsProvider);
    final failed = await actions.commit(snapshot.root, trimmed);
    if (failed != null) {
      state = CommitFailed(_explain(failed, 'commit', snapshot));
      return;
    }
    await ref.read(reviewProvider(folder).notifier).refresh();

    if (!push) {
      state = CommitDone(pushed: false, branch: snapshot.branch);
      return;
    }

    state = const CommitRunning('Pushing…');
    final rejected = await actions.push(
      snapshot.root,
      branch: snapshot.branch,
      // A branch that tracks nothing has never been pushed; Git refuses a bare
      // `push` there and tells the user to type the long form.
      setUpstream: snapshot.upstream == null,
    );
    if (rejected != null) {
      state = CommitFailed(
        _explain(rejected, 'push', snapshot),
        committed: true,
      );
      return;
    }
    await ref.read(reviewProvider(folder).notifier).refresh();
    state = CommitDone(pushed: true, branch: snapshot.branch);
  }

  /// Put the panel back to a state that isn't reporting on a finished attempt —
  /// after the user has read the outcome, or when they start typing again.
  void reset() => state = const CommitIdle();

  ReviewSnapshot? _snapshot() {
    final ready = ref.read(reviewProvider(folder)).value;
    return ready is ReviewReady ? ready.snapshot : null;
  }

  /// The sentence for [failure], with Git's raw words logged beside it (§6).
  String _explain(
    ReviewFailure failure,
    String what,
    ReviewSnapshot snapshot,
  ) => explainReviewFailure(
    failure,
    log: ref.read(appLogProvider),
    what: what,
    branch: snapshot.branch,
    remote: snapshot.upstream?.split('/').first,
  );
}
