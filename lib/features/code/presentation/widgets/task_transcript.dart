import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../playground/presentation/chat_minimap.dart';
import '../../../playground/presentation/transcript_view.dart';
import '../../logic/code_task.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/outgoing_task.dart';
import '../../logic/project_flow.dart';
import 'code_failure.dart';
import 'outgoing_turn.dart';
import 'task_turn.dart';

/// How many frames the landing scroll gets to converge on the real end of a
/// transcript it can only estimate — the same budget the chat uses, for the same
/// reason: a lazy list's extent, measured from the top, is a guess until the
/// turns below are built.
const int _snapFrames = 6;

/// Everything the team has run in this project, as a conversation — the same
/// scrolling shell the chat uses, so the two halves of the app read the same.
///
/// The grid already returns tasks oldest-first (measured: `created_at` ascends
/// down the array, newest last), which is exactly conversation order — oldest at
/// the top, newest at the bottom — so the list goes in as it arrives. The scroll
/// behaviour lives here rather than in [TranscriptView] because the two halves
/// land new turns differently — a chat streams a reply token by token, a project
/// polls a task list — and each drives its own follow.
class TaskTranscript extends ConsumerStatefulWidget {
  const TaskTranscript({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<TaskTranscript> createState() => _TaskTranscriptState();
}

class _TaskTranscriptState extends ConsumerState<TaskTranscript> {
  final _scroll = ScrollController();

  /// Whether the transcript is scrolled to (near) the bottom — drives the
  /// jump-to-latest button and whether a new turn auto-follows.
  bool _atBottom = true;

  /// The turns the last follow decision was made against, so a poll that changes
  /// nothing visible doesn't yank the view.
  String _lastSignature = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapToBottom());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - kAtBottomThreshold;
    if (atBottom != _atBottom && mounted) {
      setState(() => _atBottom = atBottom);
    }
  }

  /// Follow the newest turn when the list changes and the user was already at
  /// the bottom — a task they just sent, or one of theirs finishing.
  void _followIfChanged(List<CodeTask> tasks) {
    final signature = tasks
        .map(
          (task) => '${task.id}:${task.state.wire}:${task.resultText != null}',
        )
        .join(',');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _atBottom) _scrollToBottom();
    });
  }

  /// Follow a turn the user themselves just put up, whether or not they were at
  /// the bottom — unlike a task landing, this one is the direct answer to the
  /// Enter they pressed a frame ago, and leaving it out of sight up the
  /// transcript is exactly the "did that send?" it exists to settle.
  void _followOwnTurn() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom({bool animated = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (!animated) {
      if (_scroll.position.pixels != target) _scroll.jumpTo(target);
      return;
    }
    _scroll
        .animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        )
        .then((_) => _snapToBottom());
  }

  /// Land on the newest turn and hold there until the lazy list stops revising
  /// how tall it is — a transcript measured from the top only knows the height
  /// of the turns it has built, so one jump lands on an estimate and each
  /// re-assert sharpens it. Capped so a still-growing list can't be chased
  /// forever.
  void _snapToBottom([int frames = _snapFrames]) {
    if (!mounted || !_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (_scroll.position.pixels != target) _scroll.jumpTo(target);
    if (frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.pixels != target) return;
      if (pos.maxScrollExtent <= target) return;
      _snapToBottom(frames - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(codeTasksProvider(widget.projectId));
    // The task the user has just sent, which the grid has not given an id yet —
    // it is drawn under the list rather than in it. See [OutgoingTask].
    final outgoing = ref.watch(
      projectFlowProvider(widget.projectId).select((flow) => flow.outgoing),
    );
    // Followed off a listener, not in build: scrolling is a side effect, and
    // this build runs on every rebuild of the pane around it.
    ref.listen(codeTasksProvider(widget.projectId), (_, next) {
      final value = next.value;
      if (value != null) _followIfChanged(value);
    });
    ref.listen(
      projectFlowProvider(widget.projectId).select((flow) => flow.outgoing),
      (before, after) {
        if (before == null && after != null) _followOwnTurn();
      },
    );
    return switch (tasks) {
      // An outgoing turn is something to show, so a project whose very first
      // task is still on the wire gets the transcript rather than the "nothing
      // has been run here yet" the user has just disproved.
      AsyncData(:final value) when value.isEmpty && outgoing == null =>
        const _NothingYet(),
      AsyncData(:final value) => _build(value, outgoing),
      AsyncError(:final error) => CodeFailure(
        message: '$error',
        onRetry: () => ref.invalidate(codeTasksProvider(widget.projectId)),
      ),
      _ => const LoadingView(),
    };
  }

  Widget _build(List<CodeTask> tasks, OutgoingTask? outgoing) {
    // As the grid returns them: oldest at the top, newest at the bottom — the
    // way a conversation reads, and where the landing scroll and follow aim.
    return TranscriptView(
      scroll: _scroll,
      atBottom: _atBottom,
      onJumpToLatest: () => _scrollToBottom(animated: true),
      marksOf: () => _marks(tasks),
      rows: [
        for (final task in tasks)
          TranscriptRow(
            // Stable across the task's life, for the minimap to scroll to.
            scrollId: task.id,
            // Folds in what the turn draws differently as it changes, so a task
            // going from running to done rebuilds while an unchanged one stays
            // cached.
            cacheId:
                '${task.id}:${task.state.wire}:'
                '${task.resultText?.length ?? 0}:${task.branchPruned}',
            builder: (_) => TaskTurn(projectId: widget.projectId, task: task),
          ),
      ],
      // The outgoing turn goes in the slot the chat's streaming reply uses, for
      // the same reason: it is the one row that changes while everything above
      // it stands still, so it must not be cached with them.
      trailing: outgoing == null
          ? null
          : OutgoingTurn(
              outgoing: outgoing,
              onRetry: () => ref
                  .read(projectFlowProvider(widget.projectId).notifier)
                  .retryOutgoing(),
              onDiscard: () => ref
                  .read(projectFlowProvider(widget.projectId).notifier)
                  .discardOutgoing(),
            ),
    );
  }

  /// One rail tick per task — the request as its title, the result as its
  /// preview, the same shape the chat's ticks take.
  List<MinimapMark> _marks(List<CodeTask> ordered) => [
    for (var i = 0; i < ordered.length; i++)
      MinimapMark(
        index: i,
        text: minimapPreview(ordered[i].asked),
        reply: ordered[i].resultText == null
            ? null
            : minimapPreview(ordered[i].resultText!),
      ),
  ];
}

/// Nothing has been run here yet. No button: the box at the foot of the page is
/// the action, and it is already on screen a few inches below.
class _NothingYet extends StatelessWidget {
  const _NothingYet();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: LucideIcons.messageSquareCode300,
    title: 'Nothing has been run here yet',
    message:
        'Say what you want done. A computer on the grid runs it against this '
        'project and pushes the result to your own branch.',
  );
}
