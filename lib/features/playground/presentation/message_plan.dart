import 'package:flutter/material.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';

/// The agent's to-do plan, shown as a checklist — live in the working bubble
/// (the step it's on spins) and pinned under the finished answer (all ticked),
/// so the user sees what the agent set out to do, not just that it was busy.
/// Renders nothing when there's no plan.
class MessagePlan extends StatelessWidget {
  const MessagePlan({super.key, required this.entries});

  final List<AgentPlanEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final done = entries.where((e) => e.status == AgentPlanStatus.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.checklist_rtl,
              size: 13,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              'Plan · $done/${entries.length}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final entry in entries) _PlanRow(entry: entry),
      ],
    );
  }
}

/// One step: a status glyph, then the step text (struck through once done).
class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.entry});

  final AgentPlanEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = entry.status == AgentPlanStatus.done;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _PlanGlyph(status: entry.status),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.content,
              style: theme.textTheme.bodySmall?.copyWith(
                color: done ? AppPalette.textFaint : AppPalette.textSecondary,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The per-step glyph: an empty circle before, a spinner on the step in flight,
/// a filled check once done.
class _PlanGlyph extends StatelessWidget {
  const _PlanGlyph({required this.status});

  final AgentPlanStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads AppPalette.online
    switch (status) {
      case AgentPlanStatus.pending:
        return Icon(
          Icons.radio_button_unchecked,
          size: 13,
          color: AppPalette.textFaint,
        );
      case AgentPlanStatus.active:
        return const AppSpinner(size: SpinnerSize.small);
      case AgentPlanStatus.done:
        return Icon(Icons.check_circle, size: 13, color: AppPalette.online);
    }
  }
}
