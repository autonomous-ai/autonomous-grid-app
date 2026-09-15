/// One conversation, as a row.
///
/// Shared by the short list on the connected screen and the full list behind
/// it, because two screens showing the same thing must not drift apart in what
/// they show or what they call it.
library;

import 'package:flutter/material.dart';

import '../logic/chat_when.dart';
import '../logic/phone_chats.dart';

/// A tappable conversation row.
class ChatTile extends StatelessWidget {
  const ChatTile({
    required this.chat,
    required this.projectName,
    required this.onOpen,
    super.key,
  });

  /// The conversation this row is.
  final ChatRow chat;

  /// The project it belongs to, or empty when it belongs to none.
  final String projectName;

  /// Opens it.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = chatWhen(chat.updatedAt);
    final detail = [
      if (projectName.isNotEmpty) projectName,
      if (chat.model.isNotEmpty) chat.model,
      if (when.isNotEmpty) when,
    ].join(' · ');
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.title.isEmpty ? 'Untitled chat' : chat.title,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.textTheme.bodySmall?.color,
            ),
          ],
        ),
      ),
    );
  }
}
