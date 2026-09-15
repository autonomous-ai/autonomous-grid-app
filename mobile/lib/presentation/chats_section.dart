/// The handful of recent chats shown on the connected screen.
///
/// A window onto the history, not the history: the full list is a screen of its
/// own ([ChatListScreen]) because this one sits inside the connected screen's
/// own scroll view, and a list inside a list is a scroll nobody can drive.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chats.dart';
import 'chat_list_screen.dart';
import 'new_chat_screen.dart';
import 'parts.dart';
import 'chat_tile.dart';

/// How many conversations the connected screen shows before handing over.
const int kRecentChats = 5;

/// Recent chats, with the way to all of them.
class ChatsSection extends ConsumerWidget {
  const ChatsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final chats = ref.watch(chatListProvider);
    final projects = ref.watch(projectsProvider).value ?? const {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          'Chats',
          trailing: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const NewChatScreen()),
            ),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('New'),
          ),
        ),
        chats.when(
          loading: () => const _Loading(),
          // Short and specific: the connected screen above this one already
          // says the computer is reachable, so a failure here is about the
          // chats and must not read as the link being down.
          error: (error, _) =>
              _Problem(onRetry: () => ref.invalidate(chatListProvider)),
          data: (rows) => rows.isEmpty
              ? const _Empty()
              : Column(
                  children: [
                    for (final chat in rows.take(kRecentChats))
                      ChatTile(
                        chat: chat,
                        projectName: projects[chat.projectId]?.name ?? '',
                        onOpen: () => openChat(context, chat),
                      ),
                    if (rows.length > kRecentChats)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ChatListScreen(),
                            ),
                          ),
                          child: Text('All ${rows.length} chats'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      'No chats on your computer yet.',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            "Couldn't read your chats.",
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}
