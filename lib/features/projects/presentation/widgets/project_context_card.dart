import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../chat/logic/conversation.dart';
import '../../logic/project.dart';
import '../project_actions.dart';
import 'rail_card.dart';

/// The rail's Context card: the folder this project points at, whether it's
/// still on disk, how many chats live in it, and the two things you do with it —
/// open it, or start a chat inside it.
class ProjectContextCard extends ConsumerWidget {
  const ProjectContextCard({required this.project, super.key});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final missing = !project.exists;
    // Selected down to the count, so the rail beside a live conversation doesn't
    // rebuild on every streamed token.
    final chats = ref.watch(
      chatSessionsProvider.select(
        (s) => liveChatCountIn(s.conversations, project.id),
      ),
    );

    return RailCard(
      icon: Icons.folder_rounded,
      title: 'Context',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            project.path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textFaint,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          _StatusLine(missing: missing, chats: chats),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!missing)
                _CardAction(
                  icon: Icons.add_comment_outlined,
                  label: 'New chat',
                  onPressed: () => startProjectChat(ref, project),
                ),
              if (!missing) const SizedBox(width: 8),
              _CardAction(
                icon: Icons.drive_folder_upload_outlined,
                label: 'Open',
                onPressed: () => openProjectFolder(context, ref, project),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Whether the folder is still there, then how many chats are in it — the two
/// facts that tell the user this project is live and being used.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.missing, required this.chats});

  final bool missing;
  final int chats;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    if (missing) {
      return Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 15,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              "This folder isn't there any more.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(
          Icons.check_circle_outline_rounded,
          size: 15,
          color: AppPalette.online,
        ),
        const SizedBox(width: 7),
        Text(
          _chatsLabel(chats),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }

  static String _chatsLabel(int chats) => switch (chats) {
    0 => 'On this computer · no chats yet',
    1 => 'On this computer · 1 chat',
    _ => 'On this computer · $chats chats',
  };
}

/// A compact, quiet action inside a rail card — an icon and a short label, sized
/// to sit two-up without crowding a narrow rail.
class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        foregroundColor: AppPalette.textSecondary,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
    );
  }
}
