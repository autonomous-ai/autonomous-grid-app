/// Every conversation on the computer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_chats.dart';
import 'chat_screen.dart';
import 'chat_tile.dart';

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
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({this.projectId, this.title, super.key});

  /// Show only this project's chats, or every chat when null.
  ///
  /// One screen rather than two, because a project's chats are the same rows
  /// with the same tap — a second screen is how the two start showing different
  /// things about the same conversation.
  final String? projectId;

  /// What to call it. Null takes the plain "Chats".
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final projects = ref.watch(projectsProvider).value ?? const {};
    return Scaffold(
      appBar: AppBar(title: Text(title ?? 'Chats')),
      body: chats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ListProblem(
          message: '$error',
          onRetry: () => ref.invalidate(chatListProvider),
        ),
        data: (all) => _body(context, _visible(all), projects),
      ),
    );
  }

  List<ChatRow> _visible(List<ChatRow> all) => projectId == null
      ? all
      : [
          for (final chat in all)
            if (chat.projectId == projectId) chat,
        ];

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
        style: Theme.of(context).textTheme.bodyMedium,
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
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
