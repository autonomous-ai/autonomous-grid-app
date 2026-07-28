import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/project_rail.dart';
import '../logic/chat_sessions_controller.dart';
import 'chat_view.dart';

/// The chat section: the open conversation, edge to edge — and, when that chat
/// belongs to a project, the project's cards in a rail beside it.
///
/// The history rail lives in the app sidebar, so the conversation is the whole
/// pane; a project chat adds the same Instructions/Context/Scheduled/Memory rail
/// as the Projects screen, so what steers the assistant is in reach while you
/// talk. Falls back to a nudge when no grid is selected, since a chat needs a
/// grid to answer.
class ChatPane extends ConsumerWidget {
  const ChatPane({super.key});

  /// Below this the window is too tight for the conversation and the project
  /// rail side by side, so the rail folds away and the chat runs full width.
  static const _railBreakpoint = 960.0;
  static const _railWidth = 340.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) return const _NoGrid();

    // The project the open chat belongs to — a saved chat's own, or the one a
    // brand-new (not-yet-saved) chat is being composed in, so the rail shows
    // from the very first "New chat in this project", before any message. Select
    // it narrowly so this pane doesn't rebuild on every streamed token.
    final projectId = ref.watch(
      chatSessionsProvider.select((s) => s.openProjectId),
    );
    final project = ref.watch(projectByIdProvider(projectId));

    // The conversation always sits in the same slot (Expanded, first child) so
    // toggling the rail — switching to a plain chat, or resizing past the
    // breakpoint — never rebuilds ChatView and drops its scroll or a draft.
    return LayoutBuilder(
      builder: (context, constraints) {
        final showRail =
            project != null && constraints.maxWidth >= _railBreakpoint;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ChatView(network: network)),
            if (showRail) ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: _railWidth,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ProjectRail(project: project),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _NoGrid extends ConsumerWidget {
  const _NoGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Follow the theme so this re-colours the instant the user flips Light/Dark.
    AppTheme.watch(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messagesSquare,
            size: 40,
            color: AppPalette.textFaint,
          ),
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
