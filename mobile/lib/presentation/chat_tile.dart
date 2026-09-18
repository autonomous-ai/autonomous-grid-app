/// One conversation, as a row.
///
/// Shared by the short list on the connected screen and the full list behind
/// it, because two screens showing the same thing must not drift apart in what
/// they show or what they call it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_archive.dart';
import '../logic/chat_when.dart';
import '../logic/phone_chats.dart';
import 'parts.dart';

/// A tappable conversation row, swiped left to put away.
///
/// Swipe rather than a menu, because it is the gesture this list is shaped for
/// and the one every other iOS list uses for the same job. The swipe is
/// confirmed by the *computer*, not by the animation: [confirmDismiss] does the
/// work and refuses the dismissal when the computer does, so a row never slides
/// away over a chat that is still in the list.
class ChatTile extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return Dismissible(
      key: ValueKey(chat.id),
      direction: DismissDirection.endToStart,
      background: _SwipeAction(away: !chat.archived),
      confirmDismiss: (_) async {
        final refused = await archiveChat(
          ref,
          chatId: chat.id,
          away: !chat.archived,
        );
        if (refused == null) return true;
        if (!context.mounted) return false;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(refused)));
        return false;
      },
      child: _row(context),
    );
  }

  Widget _row(BuildContext context) {
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

/// What shows behind a row as it is swiped.
class _SwipeAction extends StatelessWidget {
  const _SwipeAction({required this.away});

  /// Whether this swipe puts the chat away or brings it back.
  final bool away;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        decoration: BoxDecoration(
          color: AppCard.inset,
          borderRadius: BorderRadius.circular(AppCard.radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              away ? Icons.archive_outlined : Icons.unarchive_outlined,
              size: 16,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              away ? 'Archive' : 'Put back',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
