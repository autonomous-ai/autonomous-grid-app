import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/project_rail.dart';
import '../logic/chat_rail.dart';
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

  /// The window width — the *whole* window, matching what a user reads as "the
  /// screen", not the pane inside the sidebar — at/above which the project rail
  /// sits beside the conversation.
  ///
  /// Below it the chat column would be too narrow for its composer (a fixed row
  /// of controls that can't shrink past ~550px, so it would overflow), so the
  /// rail steps aside by default and the top-bar toggle opens it as an overlay
  /// instead. At this width the column keeps ~615px — clear of the composer.
  static const _inlineWidth = 1240.0;

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
    final override = ref.watch(chatRailOverrideProvider);

    // Measured on the whole window, not the pane inside the sidebar.
    final width = MediaQuery.sizeOf(context).width;
    final fits = width >= _inlineWidth;
    final open = project != null && (override ?? fits);
    // The top bar can't see this pane's width, so publish the resolved
    // visibility for its toggle to mirror. Post-frame: writing a provider during
    // build would throw.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ref.read(chatRailVisibleProvider.notifier).set(open);
      }
    });
    // It sits beside the chat only when the column still clears its composer;
    // otherwise — only ever when the user forced it open on a narrow window — it
    // floats over the chat, dismissed by the scrim or the toggle.
    final inline = open && fits;
    final overlay = open && !fits;

    // ChatView always sits in the same slot — Positioned.fill in a Stack, first
    // child of the Row — so toggling the rail, overlaying it, switching to a
    // plain chat, or resizing never rebuilds ChatView and drops its scroll or a
    // half-typed draft.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: ChatView(network: network)),
              if (overlay) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () =>
                        ref.read(chatRailOverrideProvider.notifier).set(false),
                    child: const ColoredBox(color: Color(0x33000000)),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: _railWidth,
                  child: _RailPanel(project: project),
                ),
              ],
            ],
          ),
        ),
        if (inline) ...[
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
  }
}

/// The rail floated over the conversation on a window too narrow to sit it
/// alongside — a raised surface with its own edge and lift so it reads as a layer
/// above the chat, not part of it.
class _RailPanel extends StatelessWidget {
  const _RailPanel({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        border: Border(left: BorderSide(color: AppPalette.divider)),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ProjectRail(project: project),
      ),
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
