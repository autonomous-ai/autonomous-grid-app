/// One conversation, as a row.
///
/// Shared by the short list on the connected screen and the full list behind
/// it, because two screens showing the same thing must not drift apart in what
/// they show or what they call it.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_when.dart';
import '../logic/phone_chats.dart';
import 'parts.dart';

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
    AppTheme.watch(context);
    return GridListRow(
      onTap: onOpen,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chat.title.isEmpty ? 'Untitled chat' : chat.title,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                RowDetail([projectName, chat.model, chatWhen(chat.updatedAt)]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppPalette.textFaint,
          ),
        ],
      ),
    );
  }
}
