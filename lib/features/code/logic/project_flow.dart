import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_errors.dart';
import 'code_projects_controller.dart';
import 'code_workdir.dart';
import 'code_task.dart';
import 'code_tasks_controller.dart';
import 'integration.dart';
import 'project_actions.dart';
import 'project_status_controller.dart';

/// How much the user should know about something the flow did on its own.
///
/// A plain enum, not `ToastSeverity`: this is the logic layer, and the toast is
/// the screen's business — [projectFlowProvider]'s listener maps one onto the
/// other.
enum FlowLevel { info, success, warning, error }

/// Something the flow did without being asked, to be told to the user once.
///
/// [seq] makes two identical messages two different notices, so the screen's
/// listener fires on the second — "Published to the team." after each task must
/// not be swallowed because it reads the same as the last one.
class FlowNotice {
  const FlowNotice({
    required this.seq,
    required this.message,
    required this.level,
  });

  final int seq;
  final String message;
  final FlowLevel level;
}

/// Where the automatic side of a project stands.
class ProjectFlowState {
  const ProjectFlowState({
    this.awaitingPublish = const {},
    this.publishing = const {},
    this.notice,
  });

  /// Tasks this flow started that have not finished — each is promoted the
  /// moment it completes.
  final Set<String> awaitingPublish;

  /// Tasks whose promote is in flight right now.
  final Set<String> publishing;

  /// The last thing the flow did on its own, for the screen to surface.
  final FlowNotice? notice;

  /// A task of this member's is being published to the team right now.
  bool get isPublishing => publishing.isNotEmpty;

  ProjectFlowState copyWith({
    Set<String>? awaitingPublish,
    Set<String>? publishing,
    FlowNotice? notice,
  }) => ProjectFlowState(
    awaitingPublish: awaitingPublish ?? this.awaitingPublish,
    publishing: publishing ?? this.publishing,
    notice: notice ?? this.notice,
  );
}

/// The whole life of a task, made automatic: catch up before it runs, and
/// publish when it lands.
///
/// The three buttons this replaces — Catch up, Publish — were a workflow a
/// person had to remember to perform in order: pull the team's work in, ask for
/// a change, push the result out. On a project used as a conversation none of
/// that is the point of asking, so the flow does it around the send:
///
///   1. **Before the task**, bring the trunk into this member's branch, so the
///      agent builds on the team's latest rather than on stale code — which is
///      also what lets the publish afterwards be a fast-forward at all.
///   2. **After it completes**, move the trunk to the result.
///   3. **Once it has shipped**, refresh the working copy the app keeps on this
///      computer (`~/.grid/app/code/<project>`), so the code on disk is the code
///      that just landed — the third button, "Get a copy", made automatic too.
///
/// ⚠️ **Publish has no undo, and this does it with no review.** Every task a
/// member runs lands on the team's `main` the moment it finishes. That is the
/// asked-for trade — a project used like a chat — but it is a real one, and the
/// only guard is the relay's own fast-forward-only refusal.
///
/// **TODO(BE): the watch is client-side.** A task's completion is noticed by
/// this controller polling the task list, so a task that finishes after the user
/// has left the project (or closed the app) is not published until they open it
/// again. The durable place for "promote on completion" is the relay.
final projectFlowProvider = NotifierProvider.autoDispose
    .family<ProjectFlow, ProjectFlowState, String>(ProjectFlow.new);

class ProjectFlow extends Notifier<ProjectFlowState> {
  ProjectFlow(this.projectId);

  /// The project this flow drives — the family argument.
  final String projectId;

  /// Stamps each [FlowNotice] so the screen fires on repeats — see [FlowNotice].
  int _seq = 0;

  @override
  ProjectFlowState build() {
    // Watching the task list is what turns "completed" into "publish". Read
    // through `ref.listen` so this stays live as long as the project screen
    // holds this provider, and the list's own poll keeps feeding it.
    ref.listen(codeTasksProvider(projectId), (_, next) {
      final tasks = next.value;
      if (tasks != null) _onTasks(tasks);
    });
    return const ProjectFlowState();
  }

  /// Catch up, then hand the grid the task. Throws — with a message a person can
  /// read — when catching up conflicts, because the merge that resolves it takes
  /// this member's one slot and the task cannot be sent behind it.
  Future<void> submit({
    required String prompt,
    required List<String> files,
  }) async {
    await _catchUp();
    final task = await ref
        .read(codeTasksProvider(projectId).notifier)
        .create(prompt: prompt, files: files);
    // Skipped catch-up means the status wasn't reloaded, so the composer's Send
    // wouldn't know the slot is taken; make it so before returning.
    await ref.read(projectStatusProvider(projectId).notifier).refresh();
    // The user may have left the project mid-round-trip, disposing this
    // provider. Touching `ref` or `state` after that throws, so stop here — the
    // task is on the grid either way, and this flow just won't watch it.
    if (!ref.mounted) return;
    state = state.copyWith(
      awaitingPublish: {...state.awaitingPublish, task.id},
    );
    // A task can be finished the instant it is registered — a trivial one that
    // ran while the create round-trip was in flight. Check the list we already
    // have rather than wait up to a poll for the next one, so "publish when it
    // lands" doesn't sit idle on a task that has already landed.
    final tasks = ref.read(codeTasksProvider(projectId)).value;
    if (tasks != null) _onTasks(tasks);
  }

  Future<void> _catchUp() async {
    final actions = ref.read(projectActionsProvider);
    // The free read first: performing the integration is this same check, but a
    // conflicting one costs a slot and an agent run, so ask before spending.
    final preview = await actions.check(projectId);
    if (preview.status == IntegrationStatus.upToDate) return;
    final result = await actions.integrate(projectId);
    if (result.status != IntegrationStatus.mergeTask) return;
    // A merge task is now running in this member's one slot, so the task they
    // asked for cannot be created behind it. Their text is kept — this throws
    // rather than half-sends — and the merge is already in the transcript.
    throw const CodeGridException(
      'You and the team changed the same files, so a task is merging them '
      'first — it has taken your one task slot. Your request wasn’t sent; '
      'send it again once the merge lands.',
    );
  }

  /// A poll arrived: publish anything this flow was waiting on that has just
  /// finished, and drop anything that finished badly.
  void _onTasks(List<CodeTask> tasks) {
    // The listener that calls this is torn down on dispose, but `submit` calls
    // it directly after its own awaits — where the provider may already be gone.
    if (!ref.mounted || state.awaitingPublish.isEmpty) return;
    final byId = {for (final task in tasks) task.id: task};
    final stillWaiting = <String>{};
    final landed = <String>[];
    final gaveUp = <String>[];
    for (final id in state.awaitingPublish) {
      final task = byId[id];
      // Not in this page, or not finished, or finished in a state this build
      // can't read (which is deliberately not terminal): keep waiting on it.
      if (task == null || !task.state.isTerminal) {
        stillWaiting.add(id);
        continue;
      }
      (task.state == TaskState.completed ? landed : gaveUp).add(id);
    }
    if (stillWaiting.length == state.awaitingPublish.length) return;
    state = state.copyWith(awaitingPublish: stillWaiting);
    if (gaveUp.isNotEmpty) {
      _notify(
        'Your task didn’t finish, so nothing was published to the team.',
        FlowLevel.warning,
      );
    }
    for (final id in landed) {
      unawaited(_publish(id));
    }
  }

  Future<void> _publish(String taskId) async {
    // Scheduled from `_onTasks` and run later, so the project may have closed in
    // between.
    if (!ref.mounted) return;
    final memberKey = ref
        .read(projectStatusProvider(projectId))
        .value
        ?.memberKey;
    if (memberKey == null) {
      _notify(
        'Your task finished, but the grid didn’t say which member you are, so '
        'it wasn’t published. Publishing it needs that, so it’s left for you.',
        FlowLevel.warning,
      );
      return;
    }
    state = state.copyWith(publishing: {...state.publishing, taskId});
    try {
      final result = await ref
          .read(projectActionsProvider)
          .promote(projectId, memberKey);
      // Left the project while the promote was out: the trunk still moved on the
      // relay — this only can't say so — so stop rather than write a disposed
      // provider's state.
      if (!ref.mounted) return;
      _notify(
        result.advanced
            ? 'Published to the team.'
            : 'Your task changed nothing to publish.',
        result.advanced ? FlowLevel.success : FlowLevel.info,
      );
      // New code shipped, so bring the on-disk copy up to it. Fire-and-forget:
      // it is a git transfer that can take minutes, and it must not hold up the
      // "Published" the user is waiting on. Only when something actually moved —
      // a no-op publish left the copy already current.
      if (result.advanced) unawaited(_syncLocalCopy());
    } on Object catch (error) {
      // Most often the team's main moved while the task ran, so a fast-forward
      // is refused. Not swallowed and not retried behind their back: publish has
      // no undo, and the honest thing is to hand it back.
      if (!ref.mounted) return;
      _notify(
        'Your task finished but couldn’t be published on its own: $error',
        FlowLevel.error,
      );
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          publishing: state.publishing.difference({taskId}),
        );
      }
    }
  }

  /// Bring the app's working copy of this project up to what just shipped —
  /// `~/.grid/app/code/<project>`, the same fixed place the "Get a copy" button
  /// opens. Silent on success: the copy is a place the user opens when they want
  /// it, not an event. Only a failure is worth a word, and it does not touch the
  /// publish that already succeeded.
  Future<void> _syncLocalCopy() async {
    final dir = _localCopyDir();
    try {
      await ref.read(projectActionsProvider).clone(projectId, dir);
    } on Object catch (error) {
      if (!ref.mounted) return;
      _notify(
        'Published, but couldn’t refresh your copy on this computer '
        '($error). Open it again to update it.',
        FlowLevel.warning,
      );
    }
  }

  /// Where this project's working copy lives on disk — the fixed, app-owned path
  /// the header button opens and the side panel browses.
  String _localCopyDir() {
    final name = ref
        .read(codeProjectsProvider)
        .value
        ?.where((project) => project.id == projectId)
        .map((project) => project.name)
        .firstOrNull;
    return projectClonePath(projectName: name ?? '', projectId: projectId);
  }

  void _notify(String message, FlowLevel level) {
    // A last guard for every path that reports something: some run after an
    // await, where this provider may already be disposed.
    if (!ref.mounted) return;
    state = state.copyWith(
      notice: FlowNotice(seq: _seq++, message: message, level: level),
    );
  }
}
