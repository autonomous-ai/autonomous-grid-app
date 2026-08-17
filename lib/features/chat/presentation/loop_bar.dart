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
class LoopBar extends ConsumerWidget {
  const LoopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loop = ref.watch(chatSessionsProvider.select((s) => s.active?.loop));
    if (loop == null) return const SizedBox.shrink();
    final controller = ref.read(chatSessionsProvider.notifier);
    void stop() =>
        controller.runCommand((command: ChatCommand.loop, argument: 'stop'));

    return ComposerNoticeBar(
      icon: _icon(loop.status),
      label: loopBarLabel(loop, DateTime.now()),
      actions: [
        TextButton(
          onPressed: stop,
          child: Text(loop.isRunning ? 'Stop' : 'Dismiss'),
        ),
      ],
      // Not while it runs: waving it away would leave the turns coming with
      // nothing on screen saying so.
      onDismiss: loop.isRunning ? null : stop,
    );
  }
}

IconData _icon(LoopStatus status) => switch (status) {
  LoopStatus.running => Icons.repeat_rounded,
  LoopStatus.stopped => Icons.pause_circle_outline_rounded,
  LoopStatus.expired => Icons.hourglass_empty_rounded,
};
