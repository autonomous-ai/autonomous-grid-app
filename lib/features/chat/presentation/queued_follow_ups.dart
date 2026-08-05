import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';

/// The follow-ups waiting to go out in the open chat, above the composer.
///
/// Without this the queue would be invisible: the box clears when you press
/// Send, and a message that hasn't been sent yet with nothing on screen saying
/// so is indistinguishable from one that was lost. Each row shows what will be
/// sent and offers to drop it.
///
/// Nothing at all when the queue is empty — the composer stays where it was.
class QueuedFollowUps extends ConsumerWidget {
  const QueuedFollowUps({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final id = ref.watch(chatSessionsProvider.select((s) => s.activeId));
    final waiting = ref.watch(chatSessionsProvider.select((s) => s.queuedHere));
    if (id == null || waiting.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, turn) in waiting.indexed)
            _QueuedRow(
              text: turn.text,
              onCancel: () => ref
                  .read(chatSessionsProvider.notifier)
                  .cancelQueued(id, index),
            ),
        ],
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({required this.text, required this.onCancel});

  final String text;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppSurface.hoverFill,
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 13,
                color: AppPalette.textFaint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: onCancel,
                tooltip: "Don't send this",
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close_rounded, color: AppPalette.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
