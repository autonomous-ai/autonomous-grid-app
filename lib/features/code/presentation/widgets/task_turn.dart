import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/presentation/chat_bubble.dart';
import '../../../playground/presentation/message_content.dart';
import '../../logic/code_task.dart';
import '../../logic/task_event_lines.dart';
import '../../logic/task_follow_controller.dart';
import 'code_notice.dart';
import 'task_actions.dart';
import 'task_feed_view.dart';

/// One task as a pair of turns: what was asked, and what came back.
///
/// A task *is* a message — somebody asks for a change, a computer on the grid
/// answers — so it is drawn as one, in the same bubbles as the chat half of the
/// app. The transcript widgets are borrowed from the playground for exactly that
/// reason: a question typed here and a question typed in Chat must not look like
/// two different kinds of thing.
class TaskTurn extends StatefulWidget {
  const TaskTurn({super.key, required this.projectId, required this.task});

  final String projectId;
  final CodeTask task;

  @override
  State<TaskTurn> createState() => _TaskTurnState();
}

class _TaskTurnState extends State<TaskTurn> {
  /// Whether this finished turn is showing every step the agent ran.
  ///
  /// Off by default, and that is the point of the answer being separate from the
  /// working-out: a finished task is read for what it decided, and the hundreds
  /// of tool calls behind it are there when the answer doesn't explain itself.
  /// Turning it on is also what opens the replay stream, so a project's history
  /// costs one process per turn somebody actually opens.
  bool _showSteps = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatBubble(
          message: ChatMessage(role: ChatRole.user, text: task.asked),
        ),
        _Answer(
          projectId: widget.projectId,
          task: task,
          showSteps: _showSteps,
          // Only a task that has genuinely stopped has a "what it did" to
          // unfold — anything still going is already showing it, and a state
          // this build has never heard of counts as still going (see
          // [TaskState.unknown]).
          onToggleSteps: task.state.isTerminal
              ? () => setState(() => _showSteps = !_showSteps)
              : null,
        ),
      ],
    );
  }
}

/// What came back: the steps while it runs, the agent's closing words when it
/// is done, and whatever has to be said about how it ended.
class _Answer extends ConsumerWidget {
  const _Answer({
    required this.projectId,
    required this.task,
    required this.showSteps,
    required this.onToggleSteps,
  });

  final String projectId;
  final CodeTask task;
  final bool showSteps;
  final VoidCallback? onToggleSteps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Stopped, and stopped in a way this build understands. A state it does not
    // know is deliberately not terminal ([TaskState.unknown]): the task may
    // still be running, so it is watched rather than summed up.
    final finished = task.state.isTerminal;
    final said = task.resultText?.trim() ?? '';
    // Only an unfinished task holds a `grid task follow` open. A finished one
    // is replayed from the relay on demand — every turn opening its own stream
    // would put one process per task in the project on the machine.
    final feed = (!finished || showSteps)
        ? ref.watch(taskFollowProvider(task.id))
        : null;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (feed != null) ...[
              TaskFeedView(feed: feed, tail: finished ? null : kLiveTaskLines),
              if (said.isNotEmpty) const SizedBox(height: 10),
            ],
            if (said.isNotEmpty)
              MessageContent(text: said, color: AppPalette.textPrimary),
            // How it ended, but only where that isn't already obvious: a task
            // that finished and left words has said everything "Done." would.
            if (finished && !task.queueExpired && (said.isEmpty || _wentWrong))
              _Note(text: taskVerdict(task)),
            if (task.queueExpired) ...[
              const SizedBox(height: 8),
              const CodeNotice(
                message:
                    'No computer picked this up in time. The grid is short of '
                    'machines to run tasks — the task itself was fine, so it '
                    'is worth sending again once somebody is serving.',
              ),
            ],
            if (task.branchPruned) ...[
              const SizedBox(height: 8),
              const CodeNotice(
                message:
                    'The grid no longer keeps this task’s files — they were '
                    'cleared after the project’s retention window. What it did '
                    'is still recorded here.',
              ),
            ],
            TaskActions(
              projectId: projectId,
              task: task,
              showSteps: showSteps,
              onToggleSteps: onToggleSteps,
            ),
          ],
        ),
      ),
    );
  }

  /// It stopped somewhere other than "completed", so how it ended is news even
  /// when the agent left a closing note.
  bool get _wentWrong => task.state != TaskState.completed;
}

/// A quiet line under the answer — how the run ended, in the app's own words.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}
