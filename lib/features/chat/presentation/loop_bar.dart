import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/composer_notice_bar.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/commands/chat_command.dart';
import '../logic/commands/chat_loop.dart';

/// The bar above the composer while a chat is repeating a prompt on a timer.
///
/// A loop sends turns with nobody watching, so it has to be visible and it has
/// to be one click from stopping — the countdown is there so the user can see
/// what is about to happen before it happens.
///
/// Two states, two different actions, and the difference is the whole of it: a
/// **running** loop can only be stopped (the bar stays, now reading "Stopped
/// repeating…", so the stop is confirmed on screen), while a **finished** one
/// can be waved away — which drops it from the chat rather than stopping it a
/// second time. Both buttons used to do the second thing, so Dismiss and ✕ both
/// looked broken: nothing failed, nothing changed.
class LoopBar extends ConsumerWidget {
  const LoopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loop = ref.watch(chatSessionsProvider.select((s) => s.active?.loop));
    if (loop == null) return const SizedBox.shrink();
    final controller = ref.read(chatSessionsProvider.notifier);
    // `/loop stop` is the same act typed into the composer; going through
    // [runCommand] keeps one path rather than two that can drift.
    void stop() =>
        controller.runCommand((command: ChatCommand.loop, argument: 'stop'));

    return ComposerNoticeBar(
      icon: _icon(loop.status),
      label: loopBarLabel(loop, DateTime.now()),
      actions: [
        TextButton(
          onPressed: loop.isRunning ? stop : controller.dismissLoop,
          child: Text(loop.isRunning ? 'Stop' : 'Dismiss'),
        ),
      ],
      // Not while it runs: waving it away would leave the turns coming with
      // nothing on screen saying so.
      onDismiss: loop.isRunning ? null : controller.dismissLoop,
    );
  }
}

IconData _icon(LoopStatus status) => switch (status) {
  LoopStatus.running => Icons.repeat_rounded,
  LoopStatus.stopped => Icons.pause_circle_outline_rounded,
  LoopStatus.expired => Icons.hourglass_empty_rounded,
};
