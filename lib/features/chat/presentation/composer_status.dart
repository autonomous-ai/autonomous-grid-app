import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/composer_status_line.dart';
import '../../agents/presentation/running_service_notes.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/commands/chat_command.dart';
import '../logic/commands/chat_goal.dart';
import '../logic/commands/chat_loop.dart';

/// Everything working in the background right now, on one dim line under the
/// composer: a goal being worked toward, a prompt repeating on a timer, a
/// server the assistant left running.
///
/// Only things that are *still going*. A goal that has been met and a loop that
/// has stopped are news, and news is written into the transcript where it
/// happened ([TranscriptEventRow]) instead of sitting over the composer until
/// somebody closes it — which is what a stack of three or four cards up there
/// used to do.
///
/// "Still going" is [ChatGoal.hasEnded], not [ChatGoal.isRunning]: a goal the
/// user *held* has not ended, and hiding it would take away the only place
/// Resume could live. Every one of the six endings is hidden, as before.
class ComposerStatus extends ConsumerWidget {
  const ComposerStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(chatSessionsProvider.select((s) => s.active?.goal));
    final loop = ref.watch(chatSessionsProvider.select((s) => s.active?.loop));
    final controller = ref.read(chatSessionsProvider.notifier);
    // The same acts typed into the composer; going through [runCommand] keeps
    // one path rather than two that can drift.
    void run(ChatCommand command, String argument) =>
        controller.runCommand((command: command, argument: argument));

    return ComposerStatusLine(
      notes: [
        if (goal != null && !goal.hasEnded)
          StatusNote(
            icon: goal.status == GoalStatus.paused
                ? Icons.pause_circle_outline_rounded
                : Icons.flag_rounded,
            label: goalStatusNote(goal, DateTime.now()),
            actions: [
              // TODO(BE): a held goal wants Resume here as well —
              // `thread/goal/set {status: "active"}` on the Codex driver. Only
              // Codex can reach [GoalStatus.paused], so the button lands with
              // that driver rather than shipping dead now.
              TextButton(
                onPressed: () => run(ChatCommand.goal, 'clear'),
                child: const Text('Stop'),
              ),
            ],
          ),
        if (loop != null && loop.isRunning)
          StatusNote(
            icon: Icons.repeat_rounded,
            label: loopStatusNote(loop, DateTime.now()),
            actions: [
              TextButton(
                onPressed: () => run(ChatCommand.loop, 'stop'),
                child: const Text('Stop'),
              ),
            ],
          ),
        ...runningServiceNotes(ref),
      ],
    );
  }
}
