/// The turn the computer is working on right now, at the bottom of a chat.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_watch.dart';
import 'chat_bubble.dart';

/// The answer as far as it is written — or, before the first word, a line
/// saying the computer is on it.
///
/// That line is the difference between a phone that looks stuck and one that
/// looks busy: an agent can spend half a minute reading files before it writes
/// anything, and a blank space under the question reads as nothing happening.
class LiveTurnView extends StatelessWidget {
  const LiveTurnView({required this.chatId, required this.live, super.key});

  /// Which conversation.
  final String chatId;

  /// What the computer last said about it.
  final LiveTurn live;

  @override
  Widget build(BuildContext context) {
    if (live.streaming.isEmpty) return const _Working();
    return ChatBubble((
      role: 'assistant',
      text: live.streaming,
      index: -1,
      media: const [],
    ), chatId: chatId);
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
