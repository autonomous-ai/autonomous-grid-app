import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_projects_controller.dart';
import 'code_tasks_controller.dart';
import 'code_write_results.dart';
import 'integration.dart';
import 'project_status_controller.dart';

/// The commands that move refs, and the two reads that answer without moving
/// any.
///
/// They are together because they are one decision on screen: check what
/// integrating would do, do it, then publish. Splitting them across files would
/// scatter the sequence a person actually performs.
final projectActionsProvider = Provider<ProjectActions>(ProjectActions.new);

class ProjectActions {
  const ProjectActions(this._ref);

  final Ref _ref;

  /// Would integrating conflict? A pure read — no ref moves, no task is
  /// created, no slot is held.
  ///
  /// Integration **is** this check without it: asking the other way costs the
  /// member's one task slot and, when the answer is "they conflict", a paid
  /// agent run. So this is what a screen asks while deciding, and it answers
  /// even while a task is in flight, which is exactly when integrating refuses.
  Future<IntegrationPreview> check(String projectId) async {
    final json = await requireCodeCli(_ref).object(
      projectCheckArgs(projectId: projectId, grid: requireCodeGrid(_ref)),
    );
    final preview = IntegrationPreview.fromJson(json);
    if (preview == null) {
      // Somebody acts on this by deciding *not* to integrate, so a silent
      // default would make that decision for them.
      throw const CodeGridException(
        'The grid did not say what catching up would do, so nothing is shown. '
        'Try again in a moment.',
      );
    }
    return preview;
  }

  /// Bring the trunk into this member's own branch.
  ///
  /// Four outcomes, and the fourth is not free: when both sides changed the
  /// same lines the grid queues an **agent** to resolve it, which costs a run
  /// and holds this member's one task slot. Nothing has moved when that one
  /// returns.
  ///
  /// The grid verifies that the merge *happened* — that the result really
  /// contains the trunk. It cannot verify that the resolution is right.
  Future<IntegrationResult> integrate(String projectId) async {
    final json = await requireCodeCli(_ref).object(
      projectIntegrateArgs(projectId: projectId, grid: requireCodeGrid(_ref)),
    );
    final result = IntegrationResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not say what it did, so this cannot be shown as caught '
        'up. Check the project before publishing anything.',
      );
    }
    await _reload(projectId);
    return result;
  }

  /// Move the trunk to a member's branch. Fast-forward only, so a branch that
  /// is behind is refused and catching up is the fix.
  ///
  /// ⚠️ **There is no revert for this.** Code an agent wrote reaches the trunk
  /// the moment somebody publishes, and putting it back is an operation on the
  /// relay itself. [PromoteResult.previousCommit] is the only record of what it
  /// replaced.
  Future<PromoteResult> promote(String projectId, String memberKey) async {
    final json = await requireCodeCli(_ref).object(
      projectPromoteArgs(
        projectId: projectId,
        memberKey: memberKey,
        grid: requireCodeGrid(_ref),
      ),
    );
    final result = PromoteResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not say whether the shared copy moved, so this cannot be '
        'shown as published. Check the project before publishing again.',
      );
    }
    await _reload(projectId);
    return result;
  }

  /// A real working clone of the project, on this member's own branch.
  ///
  /// No credential is written: git asks `grid` for one each time, so a
  /// refreshed token is picked up instead of one written once expiring in
  /// place. **`git push` is refused** from it by design — the branch is written
  /// by the grid alone, so a task running right now cannot have the ground
  /// moved under it.
  Future<CloneResult> clone(String projectId, String directory) async {
    final json = await requireCodeCli(_ref).object(
      projectCloneArgs(
        projectId: projectId,
        directory: directory,
        grid: requireCodeGrid(_ref),
      ),
      timeout: kTransferTimeout,
    );
    final result = CloneResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not say where the copy landed. Check the folder before '
        'cloning again.',
      );
    }
    return result;
  }

  /// Land files without running an agent — "the agent got it 90% right, let me
  /// fix the last line".
  ///
  /// Holds this member's one task slot while it writes, so it is refused while
  /// they have a task in flight. An executable bit is kept without being asked
  /// for, in both directions.
  Future<CommitResult> commit({
    required String projectId,
    required String message,
    List<String> files = const [],
    List<String> deletes = const [],
  }) async {
    if (files.isEmpty && deletes.isEmpty) {
      // Refused here as well as by the CLI, because this one is answerable
      // without a round trip and the message can name what the screen offers.
      throw const CodeGridException(
        'Nothing to save — add a file to write, or a path to remove.',
      );
    }
    final json = await requireCodeCli(_ref).object(
      projectCommitArgs(
        projectId: projectId,
        message: message,
        grid: requireCodeGrid(_ref),
        files: files,
        deletes: deletes,
      ),
    );
    final result = CommitResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not say what it wrote, so this cannot be shown as saved. '
        'Check the project before saving again.',
      );
    }
    await _reload(projectId);
    return result;
  }

  /// Re-read what a write changed, so the screen shows the grid's own view
  /// rather than an optimistic guess. Both, because a conflicting integration
  /// moves no ref at all and shows up only as a new task.
  Future<void> _reload(String projectId) async {
    await _ref.read(projectStatusProvider(projectId).notifier).refresh();
    await _ref.read(codeTasksProvider(projectId).notifier).refresh();
  }
}
