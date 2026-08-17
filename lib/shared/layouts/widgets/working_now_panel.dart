import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/logic/working_chats.dart';
import '../../theme/app_theme.dart';
import 'pill_panel_shell.dart';
import 'working_now_row.dart';

/// What is answering right now, across the whole app — the panel behind the top
/// bar's working pill.
///
/// One row per chat: what it is called, where it is running, who is answering
/// and what that agent is doing this second, how long it has been at it, and a
/// stop. Opening a row jumps to that chat, because the transcript *is* the
/// progress view — a second one would be the same feed maintained twice.
///
/// App-wide, not per project: the turn worth surfacing is the one in the project
/// the user isn't looking at.
class WorkingNowPanel extends ConsumerWidget {
  const WorkingNowPanel({super.key, required this.onOpenChat});

  /// Open a chat — the pill closes the panel first, so a jump never leaves a
  /// popover hanging over the transcript it just opened.
  final ValueChanged<String> onOpenChat;

  /// Tall enough for five rows; past that the list scrolls rather than growing
  /// into a column that runs off the window.
  static const double _maxListHeight = 268;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final working = ref.watch(workingChatsProvider);
    final rows = working.rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(child: PillPanelLabel(label: 'Working now')),
            // Only worth offering above two or more: with a single chat running,
            // its own row already carries the stop it would press.
            if (rows.length > 1)
              _StopAllButton(
                onPressed: () =>
                    ref.read(chatSessionsProvider.notifier).stopAll(),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (rows.isEmpty)
          const _NothingWorking()
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              itemBuilder: (context, index) => WorkingNowRow(
                chat: rows[index],
                onOpen: () => onOpenChat(rows[index].id),
              ),
            ),
          ),
      ],
    );
  }
}

/// The panel a moment after the last turn landed, while it is still pinned open
/// — honest about being empty rather than vanishing mid-read.
class _NothingWorking extends StatelessWidget {
  const _NothingWorking();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        'Nothing is working right now.',
        style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
      ),
    );
  }
}

/// "Stop all" — small and quiet, in the panel's heading row.
class _StopAllButton extends StatefulWidget {
  const _StopAllButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_StopAllButton> createState() => _StopAllButtonState();
}

class _StopAllButtonState extends State<_StopAllButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Semantics(
          button: true,
          child: Text(
            'Stop all',
            style: TextStyle(
              fontSize: 11,
              fontWeight: AppFont.medium,
              color: _hovered
                  ? Theme.of(context).colorScheme.error
                  : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
