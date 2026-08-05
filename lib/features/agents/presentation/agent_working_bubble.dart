import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../playground/presentation/message_plan.dart';
import '../../playground/presentation/message_sources.dart';
import '../logic/agent_providers.dart';
import '../logic/agent_step_label.dart';

/// The "agent is working" bubble shown in the chat while the agent is answering
/// but before it has streamed any text.
///
/// Deliberately distinct from the media `GeneratingBubble` (an agent turn
/// produces text, not a percentage): a live feed of the steps the agent runs —
/// each shell command and tool call with its status, and a "Thinking…" line
/// while it composes the next one — so the user sees *what* it is doing, not
/// just that it's busy. The feed carries its own spinner, so there is no
/// separate "working" header to say the same thing twice.
class AgentWorkingBubble extends StatelessWidget {
  const AgentWorkingBubble({super.key});

  @override
  Widget build(BuildContext context) {
    // No fill: the feed sits bare at the assistant column's left edge, exactly
    // where its text lands once it starts streaming (see [_StreamingReply]), so
    // "thinking" and the answer that follows share one left margin instead of
    // the steps jumping out of a tinted box the moment the first token arrives.
    return const Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: AgentActivityFeed(leadingGap: false),
      ),
    );
  }
}

/// The live feed under an in-flight agent turn: its to-do plan, the steps it is
/// running (each shell command or tool call, with status), and a "Thinking…"
/// line — carrying its own spinner — while it composes the next step.
///
/// The shared body of both [AgentWorkingBubble] and the chat's streaming reply,
/// so a turn that has *already begun narrating* still shows what it is doing —
/// before this was extracted, the moment the agent streamed a first sentence the
/// chat swapped the working bubble for plain text and the steps vanished behind a
/// row of dots. [leadingGap] leaves room above the first row when the feed
/// follows other content (a streaming reply); it is off when the feed is the
/// whole bubble.
class AgentActivityFeed extends ConsumerWidget {
  const AgentActivityFeed({super.key, this.leadingGap = true});

  final bool leadingGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(agentActivityProvider);
    final sources = ref.watch(agentSourcesProvider);
    final plan = ref.watch(agentPlanProvider);
    // How much of the working-out to show. At [AgentDetailMode.answer] the feed
    // is only the "Thinking…" line and whatever the answer cites — the user
    // asked not to be shown the machinery.
    final detail = ref.watch(chatPrefsProvider.select((p) => p.detail));
    final showSteps = detail != AgentDetailMode.answer;
    // This feed only exists during an in-flight turn, so when nothing is
    // actively running the model is composing its next step. Show that, with a
    // live count, so a long pause reads as work rather than a stall.
    final thinking = steps.every(
      (step) => step.status != AgentActivityStatus.running,
    );
    final sections = <Widget>[
      if (showSteps && plan.isNotEmpty) MessagePlan(entries: plan),
      if (showSteps && steps.isNotEmpty)
        _StepList(steps: steps, detail: detail),
      if (thinking)
        // Reset the elapsed count each time the step list changes, so it reads
        // as time since the last action, not since the turn began.
        _ThinkingRow(key: ValueKey(steps.length)),
      if (sources.isNotEmpty) MessageSources(sources: sources),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0 || leadingGap) SizedBox(height: i == 0 ? 10 : 8),
          sections[i],
        ],
      ],
    );
  }
}

/// The run's steps: shown in full when there are few, or folded behind a tappable
/// "N steps" summary when there are many.
///
/// Folded, it still shows the latest handful (see [foldedActivitySteps]), so a
/// live turn never looks stalled — only the history tucks away. The choice is
/// per run: this widget lives only while the feed holds steps, so the next turn
/// (which starts empty) gets a fresh, default view rather than inheriting the
/// last one's.
class _StepList extends StatefulWidget {
  const _StepList({required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  State<_StepList> createState() => _StepListState();
}

class _StepListState extends State<_StepList> {
  /// The user's explicit open/closed choice, or null to follow the default
  /// (folded once the run is long).
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.length <= kFoldedStepLimit) {
      return _StepColumn(steps: steps, detail: widget.detail);
    }

    final expanded = _expanded ?? false;
    final shown = expanded ? steps : foldedActivitySteps(steps);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepsHeader(
          count: steps.length,
          status: aggregateActivityStatus(steps),
          expanded: expanded,
          onTap: () => setState(() => _expanded = !expanded),
        ),
        _StepColumn(steps: shown, detail: widget.detail),
      ],
    );
  }
}

/// A plain column of step rows — the shape shared by the short-run view and the
/// expanded long-run view.
class _StepColumn extends StatelessWidget {
  const _StepColumn({required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [for (final step in steps) _StepRow(step: step, detail: detail)],
  );
}

/// The tappable summary row for a folded run: its overall status, the step count,
/// and a chevron that flips as it opens.
class _StepsHeader extends StatelessWidget {
  const _StepsHeader({
    required this.count,
    required this.status,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final AgentActivityStatus status;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(8);
    return Semantics(
      button: true,
      label: expanded ? 'Hide steps' : 'Show all $count steps',
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          // A menu-style click, not the app's Android ripple spreading across the
          // row; the hover wash is the whole feedback.
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppSurface.hoverFill,
          child: Padding(
            // No left inset, so the summary's status dot lines up with the step
            // rows' dots below it (they start at the column's left edge); a touch
            // on the right just keeps the hover wash off the chevron.
            padding: const EdgeInsets.fromLTRB(0, 3, 6, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(status: status),
                const SizedBox(width: 8),
                Text(
                  '$count steps',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: AppFont.medium,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "the model is composing its next step" line, shown in the feed while a
/// turn is in flight but nothing is running — a small spinner and the seconds
/// elapsed, so a pause between commands (long when the context is large) reads
/// as work in progress rather than a hang.
class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow({super.key});

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow> {
  Timer? _tick;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds += 1);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _seconds > 0 ? 'Thinking… ${_seconds}s' : 'Thinking…';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 8),
          Icon(
            Icons.psychology_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One line in the feed: a status indicator, a kind icon, and the step label.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.detail});

  final AgentActivity step;
  final AgentDetailMode detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (step.kind) {
      AgentActivityKind.command => Icons.terminal,
      AgentActivityKind.web => Icons.public,
      AgentActivityKind.tool => Icons.build_outlined,
      AgentActivityKind.thinking => Icons.psychology_outlined,
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
              agentStepLabel(step, detail),
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
