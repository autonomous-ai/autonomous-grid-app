import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../playground/presentation/message_plan.dart';
import '../../playground/presentation/message_sources.dart';
import '../logic/agent_providers.dart';

/// The "agent is working" bubble shown in the chat while the agent is answering.
///
/// Deliberately distinct from the media `GeneratingBubble` (an agent turn
/// produces text, not a percentage): a spinner header plus a live feed of the
/// steps the agent runs — each shell command and tool call, with its status —
/// so the user can see *what* the agent is doing, not just that it's busy.
class AgentWorkingBubble extends StatelessWidget {
  const AgentWorkingBubble({super.key});

  @override
  Widget build(BuildContext context) {
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
                const AppSpinner(),
                const SizedBox(width: 10),
                Text('Agent is working…', style: theme.textTheme.bodyMedium),
              ],
            ),
            const AgentActivityFeed(),
          ],
        ),
      ),
    );
  }
}

/// The live feed under an in-flight agent turn: its to-do plan, the steps it is
/// running (each shell command or tool call, with status), and any web sources.
///
/// The shared body of both [AgentWorkingBubble] and the chat's streaming reply,
/// so a turn that has *already begun narrating* still shows what it is doing —
/// before this was extracted, the moment the agent streamed a first sentence the
/// chat swapped the working bubble for plain text and the steps vanished behind a
/// row of dots. Renders nothing (no spacing) while there is nothing to show.
class AgentActivityFeed extends ConsumerWidget {
  const AgentActivityFeed({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(agentActivityProvider);
    final sources = ref.watch(agentSourcesProvider);
    final plan = ref.watch(agentPlanProvider);
    if (plan.isEmpty && steps.isEmpty && sources.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (plan.isNotEmpty) ...[
          const SizedBox(height: 10),
          MessagePlan(entries: plan),
        ],
        if (steps.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final step in steps) _StepRow(step: step),
        ],
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          MessageSources(sources: sources),
        ],
      ],
    );
  }
}

/// One line in the feed: a status indicator, a kind icon, and the step label.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final AgentActivity step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (step.kind) {
      AgentActivityKind.command => Icons.terminal,
      AgentActivityKind.web => Icons.public,
      AgentActivityKind.tool => Icons.build_outlined,
    };
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

  final AgentActivityStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads AppPalette.online
    switch (status) {
      case AgentActivityStatus.running:
        return const AppSpinner(size: SpinnerSize.small);
      case AgentActivityStatus.done:
        return Icon(Icons.check_circle, size: 14, color: AppPalette.online);
      case AgentActivityStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 14,
          color: Theme.of(context).colorScheme.error,
        );
    }
  }
}
