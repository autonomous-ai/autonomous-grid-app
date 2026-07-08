import 'package:flutter/material.dart';

import '../logic/chat_message.dart';
import 'message_content.dart';

/// One transcript turn — the user's message (accent, right-aligned) or the
/// assistant's reply (surface, left-aligned). Renders text and/or inline media
/// via [MessageContent]. Shared by the Playground dialog and the Chat tab.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: MessageContent(
          text: message.text,
          media: message.media,
          color: isUser
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}

/// A live progress bubble while a media generation streams — percent plus the
/// relay's short status label, with an indeterminate bar until the first update.
class GeneratingBubble extends StatelessWidget {
  const GeneratingBubble({super.key, required this.phase});
  final SendGenerating phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (phase.progress * 100).round();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 16),
                const SizedBox(width: 8),
                Text('Generating… $pct%', style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: phase.progress <= 0 ? null : phase.progress,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
