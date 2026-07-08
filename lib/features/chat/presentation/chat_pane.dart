import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import 'chat_view.dart';
import 'conversation_sidebar.dart';

/// The Chat section: a conversation-history rail on the left, the open
/// conversation on the right (Ollama-style). Falls back to a nudge when no grid
/// is selected, since a chat needs a grid to answer.
class ChatPane extends ConsumerWidget {
  const ChatPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) return const _NoGrid();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ConversationSidebar(),
        const VerticalDivider(width: 1),
        Expanded(child: ChatView(network: network)),
      ],
    );
  }
}

class _NoGrid extends StatelessWidget {
  const _NoGrid();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: AppPalette.textFaint),
          SizedBox(height: 12),
          Text(
            'Select a grid to start chatting.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}
