import 'package:flutter/material.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';

/// The agent's to-do plan, shown as a checklist — live in the working bubble
/// (the step it's on spins) and pinned under the finished answer, so the user
/// sees what the agent set out to do, not just that it was busy. Renders nothing
/// when there's no plan.
class MessagePlan extends StatelessWidget {
  const MessagePlan({super.key, required this.entries, this.live = false});

  final List<AgentPlanEntry> entries;

  /// Whether the turn is still running.
  ///
  /// Live (the working bubble): the step in flight spins. Pinned under a
  /// finished turn: nothing is running, so the step it stopped on is drawn
  /// static rather than spinning forever — a spinner on a turn that has ended
  /// says work is happening when none is (§5). "Finished" is not "all done": a
  /// turn can stop mid-plan (Codex ended 0/6 with step one still in progress),
  /// and the checklist has to be honest about that.
  final bool live;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    // Reads AppPalette tokens — follow theme flips. It rides inside a transcript
    // bubble, which a lazy list keeps built across a flip.
    AppTheme.watch(context);
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
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final entry in entries) _PlanRow(entry: entry, live: live),
      ],
    );
  }
}

/// One step: a status glyph, then the step text (struck through once done).
class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.entry, required this.live});

  final AgentPlanEntry entry;
  final bool live;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final done = entry.status == AgentPlanStatus.done;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _PlanGlyph(status: entry.status, live: live),
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

/// The per-step glyph: an empty circle before, the step in flight (a spinner
/// while the turn runs, a filled dot once it has stopped there), a check once
/// done.
class _PlanGlyph extends StatelessWidget {
  const _PlanGlyph({required this.status, required this.live});

  final AgentPlanStatus status;

  /// Whether the turn is still running — see [MessagePlan.live].
  final bool live;

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
        // Spins only while the turn is live. On a finished turn this is the step
        // the agent stopped on: a filled dot, so it reads as the unfinished
        // step it is rather than work still in progress.
        return live
            ? const AppSpinner(size: SpinnerSize.small)
            : Icon(
                Icons.radio_button_checked,
                size: 13,
                color: AppPalette.textSecondary,
              );
      case AgentPlanStatus.done:
        return Icon(Icons.check_circle, size: 13, color: AppPalette.online);
    }
  }
}
