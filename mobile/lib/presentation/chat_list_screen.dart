/// Every conversation on the computer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chats.dart';
import 'chat_screen.dart';
import 'chat_tile.dart';
import 'grid_app_bar.dart';
import 'parts.dart';
import 'new_chat_screen.dart';

/// Pushes the transcript of [chat].
///
/// One function rather than two copies of the same `Navigator.push`: the short
/// list and the full list open a chat the same way, and a second copy is how
/// they stop doing so.
void openChat(BuildContext context, ChatRow chat) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(id: chat.id, title: chat.title),
    ),
  );
}

/// The full, scrollable list of chats, or of one project's chats.
///
/// A screen when it is pushed — from a project, or from the archive. The tab at
/// the root of the app shows the same [ChatListBody] without this frame, so the
/// two are one list rather than two that drift.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({
    this.projectId,
    this.title,
    this.archived = false,
    super.key,
  });

  /// Show the chats that have been put away instead of the ones in play.
  ///
  /// The same screen rather than a second one: an archived chat is the same row
  /// with the same tap, and the swipe on it means "put back" instead of "put
  /// away". Two screens would be two places for that row to drift.
  final bool archived;

  /// Show only this project's chats, or every chat when null.
  ///
  /// One screen rather than two, because a project's chats are the same rows
  /// with the same tap — a second screen is how the two start showing different
  /// things about the same conversation.
  final String? projectId;

  /// What to call it. Null takes the plain "Chats".
  final String? title;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      appBar: GridAppBar(title: title ?? (archived ? 'Archived' : 'Chats')),
      // Carries the project through, so starting a chat from inside one lands
      // it there instead of making somebody pick the project they are looking
      // at.
      // No way to start a chat from the archive: that screen is about what
      // has been put away, and a new chat would immediately leave it.
      floatingActionButton: archived
          ? null
          : NewChatButton(projectId: projectId),
      body: ChatListBody(projectId: projectId, archived: archived),
    );
  }
}

/// The list itself: every conversation, or one project's, or the archive.
class ChatListBody extends ConsumerWidget {
  const ChatListBody({this.projectId, this.archived = false, super.key});

  /// Show what has been put away instead of what is in play.
  final bool archived;

  /// Narrow to one project, or every chat when null.
  final String? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final chats = ref.watch(chatListProvider);
    final projects = ref.watch(projectsProvider).value ?? const {};
    return chats.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ListProblem(
        message: '$error',
        onRetry: () => ref.invalidate(chatListProvider),
      ),
      data: (all) => _body(context, _visible(all), projects),
    );
  }

  List<ChatRow> _visible(List<ChatRow> all) {
    final half = archived ? archivedChats(all) : liveChats(all);
    if (projectId == null) return half;
    return [
      for (final chat in half)
        if (chat.projectId == projectId) chat,
    ];
  }

  Widget _body(
    BuildContext context,
    List<ChatRow> rows,
    Map<String, ProjectRow> projects,
  ) => rows.isEmpty
      ? const _NoChats()
      // Long and unbounded — this is the whole history, which is 251
      // conversations on the machine this was built against.
      : ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          itemBuilder: (context, index) => ChatTile(
            chat: rows[index],
            projectName: projects[rows[index].projectId]?.name ?? '',
            onOpen: () => openChat(context, rows[index]),
          ),
        );
}

/// The one way to start a conversation, wherever the list is shown.
class NewChatButton extends StatelessWidget {
  const NewChatButton({this.projectId, super.key});

  /// The project a new chat should land in, or null for none.
  final String? projectId;

  @override
  Widget build(BuildContext context) => GridFab(
    tooltip: 'New chat',
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NewChatScreen(projectId: projectId),
      ),
    ),
  );
}

/// Nothing to list, and what to do about it.
class _NoChats extends StatelessWidget {
  const _NoChats();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        'No chats on your computer yet. Start one in Grid over there and it '
        'will show up here.',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
      ),
    ),
  );
}

class _ListProblem extends StatelessWidget {
  const _ListProblem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
