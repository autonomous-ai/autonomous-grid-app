/// The turn the computer is working on right now, at the bottom of a chat.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';
import 'chat_bubble.dart';
import 'permission_card.dart';
import 'step_fold.dart';

/// What the agent is waiting on, what it has run, and the answer so far.
///
/// In the order the person needs them: a question first, because nothing moves
/// until it is answered; then the newest steps, which is what "is it doing
/// anything" is asking; then the words. Before any of that, a line saying the
/// computer is on it — an agent can spend half a minute reading files before
/// it writes anything, and a blank space under the question reads as nothing
/// happening.
class LiveTurnView extends ConsumerWidget {
  const LiveTurnView({required this.chatId, required this.live, super.key});

  /// Which conversation.
  final String chatId;

  /// What the computer last said about it.
  final MobileLiveTurn live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAnswer = ref.watch(
      phoneLinkProvider.select((state) => shownLink(state)?.canAnswer ?? false),
    );
    final question = live.permission;
    final quiet = live.streaming.isEmpty && live.steps.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (question != null)
          PhonePermissionCard(
            chatId: chatId,
            question: question,
            canAnswer: canAnswer,
          ),
        StepFold(steps: live.steps, count: live.stepCount, live: true),
        if (live.streaming.isNotEmpty)
          ChatBubble((
            role: 'assistant',
            text: live.streaming,
            index: -1,
            media: const [],
            steps: const [],
            stepCount: 0,
          ), chatId: chatId)
        else if (quiet && question == null)
          const _Working(),
      ],
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppPalette.textFaint,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Working…',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}
