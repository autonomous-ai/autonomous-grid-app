import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

/// The Chat history rail (Ollama-style): a "New chat" action on top, then the
/// saved conversations grouped by recency. Selecting one opens it; hovering a
/// row reveals a delete button.
class ConversationSidebar extends ConsumerWidget {
  const ConversationSidebar({super.key});

  static const double width = 240;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(chatSessionsProvider);
    final controller = ref.read(chatSessionsProvider.notifier);
    final groups = groupConversationsByRecency(
      sessions.conversations,
      DateTime.now(),
    );

    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NewChatButton(
              enabled: !sessions.sending,
              onTap: controller.newChat,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: groups.isEmpty
                  ? const _EmptyHistory()
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final group in groups) ...[
                          _GroupHeader(label: group.label),
                          for (final conversation in group.conversations)
                            _ConversationTile(
                              title: conversation.title,
                              selected: conversation.id == sessions.activeId,
                              onTap: () => controller.select(conversation.id),
                              onDelete: () => controller
                                  .deleteConversation(conversation.id),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Starts a fresh conversation. Styled like the primary nav items so it reads as
/// the rail's main action.
class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(10));
    return Material(
      color: AppGlass.selected,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: const [
              Icon(Icons.edit_outlined, size: 17, color: AppPalette.textPrimary),
              SizedBox(width: 10),
              Text(
                'New chat',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A recency bucket label (Today / Yesterday / …) above its conversations.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
      child: Text(
        label,
        style: const TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// One history row. The delete button fades in on hover so the rail stays quiet
/// until you reach for it.
class _ConversationTile extends StatefulWidget {
  const _ConversationTile({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color =
        widget.selected ? AppPalette.textPrimary : AppPalette.textSecondary;
    const radius = BorderRadius.all(Radius.circular(9));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: widget.selected ? AppGlass.selected : Colors.transparent,
            border: widget.selected
                ? Border.all(color: AppGlass.selectedBorder)
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    // Reserve the slot at a fixed height whether or not the
                    // delete button is showing, so hovering never resizes the
                    // row (which made the list jump).
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: _hovered
                          ? _DeleteButton(onDelete: widget.onDelete)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

/// Shown when there's no saved history yet — a quiet nudge, not a dead panel.
class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Your chats will show up here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
        ),
      ),
    );
  }
}
