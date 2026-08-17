import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/composer_notice_bar.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/commands/chat_command.dart';
import '../logic/commands/chat_goal.dart';

/// The bar above the composer while a chat is working toward a goal — or has
/// stopped working toward one.
///
/// A goal sends turns on its own, so something has to say so at all times, and
/// say *which* way it ended: met, judged impossible, or stalled. One word for
/// all three is the bug that shipped as issue #33 (§5).
class GoalBar extends ConsumerWidget {
  const GoalBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(chatSessionsProvider.select((s) => s.active?.goal));
    if (goal == null) return const SizedBox.shrink();
    final controller = ref.read(chatSessionsProvider.notifier);
    // `/goal clear` is the same act from the composer; going through
    // [runCommand] keeps one path rather than two that can drift.
    void clear() =>
        controller.runCommand((command: ChatCommand.goal, argument: 'clear'));

    return ComposerNoticeBar(
      icon: _icon(goal.status),
      label: goalBarLabel(goal, DateTime.now()),
      actions: [
        TextButton(
          onPressed: clear,
          child: Text(goal.isRunning ? 'Stop' : 'Clear goal'),
        ),
      ],
      // While it runs, stopping is the way out: waving the bar away would leave
      // the turns coming with nothing on screen saying why.
      onDismiss: goal.isRunning ? null : clear,
    );
  }
}

IconData _icon(GoalStatus status) => switch (status) {
  GoalStatus.active => Icons.flag_rounded,
  GoalStatus.met => Icons.check_circle_outline_rounded,
  GoalStatus.impossible => Icons.error_outline_rounded,
  GoalStatus.stalled => Icons.pause_circle_outline_rounded,
};
