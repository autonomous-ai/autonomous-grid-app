import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/presentation/chat_bubble.dart';
import '../../logic/outgoing_task.dart';
import 'code_notice.dart';

/// The turn for a task that has been sent but not yet taken by the grid.
///
/// Deliberately the same bubble a real task gets — a question does not change
/// what it is while the round trip that registers it is out, and a second
/// treatment for "nearly a task" would read as a different kind of thing. What
/// is under it is the whole difference: a line saying it is on its way, or, when
/// the grid refused it, why and a way to send it again.
class OutgoingTurn extends StatelessWidget {
  const OutgoingTurn({
    super.key,
    required this.outgoing,
    required this.onRetry,
    required this.onDiscard,
  });

  final OutgoingTask outgoing;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ChatBubble(
        message: ChatMessage(role: ChatRole.user, text: outgoing.prompt),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: switch (outgoing.phase) {
            TaskSending() => const _OnItsWay(),
            TaskSendFailed(:final message) => _Refused(
              message: message,
              onRetry: onRetry,
              onDiscard: onDiscard,
            ),
          },
        ),
      ),
    ],
  );
}

/// On its way to the grid. Quiet on purpose: the answer is seconds away, and
/// the point of the line is only that the question was heard.
class _OnItsWay extends StatelessWidget {
  const _OnItsWay();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 9),
          Text(
            'Sending this to the grid…',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// It never got there. The question is still above, so the two things worth
/// offering are the two here: send that same task again, or take it down.
class _Refused extends StatelessWidget {
  const _Refused({
    required this.message,
    required this.onRetry,
    required this.onDiscard,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 6),
      CodeNotice(message: message, icon: Icons.error_outline_rounded),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onRetry, child: const Text('Send it again')),
          TextButton(onPressed: onDiscard, child: const Text('Discard')),
        ],
      ),
    ],
  );
}
