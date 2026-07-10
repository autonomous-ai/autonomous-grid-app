import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/codex_event.dart';
import '../logic/codex_providers.dart';

/// The "agent is working" bubble shown in the Chat tab while an Agent-mode
/// (codex) run is in flight.
///
/// Deliberately distinct from the media `GeneratingBubble` (an agent turn
/// produces text, not a percentage): a spinner header plus a live feed of the
/// steps the agent runs — each shell command and tool call, with its status —
/// so the user can see *what* the agent is doing, not just that it's busy.
class AgentWorkingBubble extends ConsumerWidget {
  const AgentWorkingBubble({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(codexActivityProvider);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 440),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text('Agent is working…', style: theme.textTheme.bodyMedium),
              ],
            ),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final step in steps) _StepRow(step: step),
            ],
          ],
        ),
      ),
    );
  }
}

/// One line in the feed: a status indicator, a kind icon, and the step label.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final CodexActivity step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = step.kind == CodexActivityKind.command
        ? Icons.terminal
        : Icons.build_outlined;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          _StatusDot(status: step.status),
          const SizedBox(width: 8),
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              step.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A per-step status glyph: a spinner while running, a check when done, an
/// error mark when it failed.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final CodexActivityStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case CodexActivityStatus.running:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        );
      case CodexActivityStatus.done:
        return const Icon(Icons.check_circle, size: 14, color: Colors.green);
      case CodexActivityStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: Theme.of(context).colorScheme.error,
        );
    }
  }
}
