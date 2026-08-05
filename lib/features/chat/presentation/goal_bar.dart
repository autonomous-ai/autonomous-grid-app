import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/composer_notice_bar.dart';
import '../logic/chat_goal.dart';
import '../logic/chat_sessions_controller.dart';

/// The bar above the composer while the open chat is working toward a goal — or
/// has stopped working toward one.
///
/// A goal sends turns on its own, so something on screen has to say so at all
/// times, and say *which* of the four ways it stopped: paused by the user, met,
/// out of budget, or blocked by a failure. One word for all four would leave the
/// user unable to tell "it finished" from "it gave up" (§5).
class GoalBar extends ConsumerWidget {
  const GoalBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(chatSessionsProvider.select((s) => s.active?.goal));
    if (goal == null) return const SizedBox.shrink();
    final controller = ref.read(chatSessionsProvider.notifier);

    return ComposerNoticeBar(
      icon: _icon(goal.status),
      label: goalBarLabel(goal, DateTime.now()),
      actions: [
        if (goal.isRunning)
          TextButton(
            onPressed: controller.pauseGoal,
            child: const Text('Pause'),
          )
        else ...[
          TextButton(
            onPressed: controller.dropGoal,
            child: const Text('Drop goal'),
          ),
          // Every stopped state can be picked up again; what differs is what
          // resuming means, which the label above has already said.
          TextButton(
            onPressed: controller.resumeGoal,
            child: Text(_resumeLabel(goal.status)),
          ),
        ],
      ],
      // While it is running, dropping the goal is the way out — the bar is not
      // something to wave away, because the turns would keep coming.
      onDismiss: goal.isRunning ? null : controller.dropGoal,
    );
  }
}

IconData _icon(GoalStatus status) => switch (status) {
  GoalStatus.active => Icons.flag_rounded,
  GoalStatus.paused => Icons.pause_circle_outline_rounded,
  GoalStatus.done => Icons.check_circle_outline_rounded,
  GoalStatus.spent => Icons.hourglass_empty_rounded,
  GoalStatus.blocked => Icons.error_outline_rounded,
};

String _resumeLabel(GoalStatus status) => switch (status) {
  // Out of budget: the button is a grant of more, so it says that rather than
  // "resume", which would suggest picking up an unfinished allowance.
  GoalStatus.spent => 'Give it more',
  GoalStatus.blocked => 'Try again',
  _ => 'Resume',
};

/// The bar's one line for [goal] at [now] — pure, so what each state says is
/// tested rather than discovered by getting into it.
String goalBarLabel(ChatGoal goal, DateTime now) => switch (goal.status) {
  GoalStatus.active =>
    'Working toward: ${goal.objective} · ${goal.budgetLabel(now)}',
  GoalStatus.paused => 'Paused: ${goal.objective}',
  GoalStatus.done => 'Goal met: ${goal.objective}',
  GoalStatus.spent =>
    'Out of budget after ${goal.turnsUsed} turns, with the goal unmet: '
        '${goal.objective}',
  GoalStatus.blocked =>
    'Stopped — ${goal.note ?? 'a turn failed'}. The goal is unmet.',
};
