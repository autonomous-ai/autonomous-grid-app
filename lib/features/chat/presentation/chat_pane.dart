import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import 'chat_view.dart';

/// The chat section: the open conversation, edge to edge. The history rail lives
/// in the app sidebar, so this pane is only ever the conversation itself.
///
/// Falls back to a nudge when no grid is selected, since a chat needs a grid to
/// answer.
class ChatPane extends ConsumerWidget {
  const ChatPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) return const _NoGrid();
    return ChatView(network: network);
  }
}

class _NoGrid extends ConsumerWidget {
  const _NoGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: AppPalette.textFaint),
          const SizedBox(height: 12),
          Text(
            'Pick a grid to chat with.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.grids),
            child: const Text('Open grids'),
          ),
        ],
      ),
    );
  }
}
