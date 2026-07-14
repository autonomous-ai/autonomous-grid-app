import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

/// The saved conversations, grouped by recency (Today / Yesterday / …), as rows
/// in the sidebar. Selecting one opens it; hovering reveals a delete button.
///
/// [query] filters by title — the sidebar's search box types into it — so a long
/// history stays findable instead of turning into an endless scroll.
class ChatHistoryList extends ConsumerWidget {
  const ChatHistoryList({super.key, this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(chatSessionsProvider);
    final controller = ref.read(chatSessionsProvider.notifier);
    final matches = _filter(sessions.conversations, query);

    if (matches.isEmpty) return _Empty(searching: query.trim().isNotEmpty);

    final groups = groupConversationsByRecency(matches, DateTime.now());
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final group in groups) ...[
          SidebarSectionLabel(label: group.label),
          for (final conversation in group.conversations)
            SidebarItem(
              label: conversation.title,
              selected: conversation.id == sessions.activeId,
              // Opening a chat from anywhere in the app puts you back in it —
              // otherwise clicking a conversation while Grids is open would
              // silently change the chat behind the screen you're looking at.
              onTap: () {
                controller.select(conversation.id);
                ref
                    .read(shellSectionProvider.notifier)
                    .select(ShellSection.chat);
              },
              trailing: _DeleteButton(
                onDelete: () => controller.deleteConversation(conversation.id),
              ),
            ),
        ],
      ],
    );
  }

  List<Conversation> _filter(List<Conversation> all, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final c in all)
        if (c.title.toLowerCase().contains(q)) c,
    ];
  }
}

/// Hover-revealed delete affordance for a history row.
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Delete chat',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      iconSize: 15,
      splashRadius: 14,
      color: AppPalette.textSecondary,
      icon: const Icon(Icons.delete_outline_rounded),
      onPressed: onDelete,
    );
  }
}

/// Shown when there's nothing to list — no chats yet, or none matching the
/// search. A quiet nudge, not a dead panel.
class _Empty extends StatelessWidget {
  const _Empty({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 0),
      child: Text(
        searching ? 'No chats match that.' : 'Your chats will show up here.',
        style: const TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
