import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../playground/presentation/message_plan.dart';
import '../../playground/presentation/message_sources.dart';
import '../logic/agent_providers.dart';
import 'agent_turn_view.dart';

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
  const AgentWorkingBubble({super.key, required this.chatId});

  /// The conversation whose turn this is. Runs are keyed by chat (turns go on in
  /// several projects at once), so the bubble has to say which one it speaks for
  /// rather than reading "the" feed.
  final String chatId;

  @override
  Widget build(BuildContext context) {
    // No fill: the feed sits bare at the assistant column's left edge, exactly
    // where its text lands once it starts streaming (see [_StreamingReply]), so
    // "thinking" and the answer that follows share one left margin instead of
    // the steps jumping out of a tinted box the moment the first token arrives.
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: AgentActivityFeed(chatId: chatId, leadingGap: false),
      ),
    );
  }
}

/// The live feed under an in-flight agent turn: the turn as it happens — what it
/// has said and the steps it has run, in order — then its to-do plan, a
/// "Thinking…" line carrying its own spinner while it composes the next step,
/// and the pages it has cited.
///
/// The shared body of both [AgentWorkingBubble] and the chat's streaming reply,
/// so a turn that has *already begun narrating* still shows what it is doing —
/// before this was extracted, the moment the agent streamed a first sentence the
/// chat swapped the working bubble for plain text and the steps vanished behind a
/// row of dots. [leadingGap] leaves room above the first row when the feed
/// follows other content; it is off when the feed is the whole bubble.
///
/// [answer] is the passage still streaming in, drawn at the end of the timeline
/// — the one part of a turn that changes on every token, so the chat hands it
/// down ready-built (and throttled) rather than watching it from here.
class AgentActivityFeed extends ConsumerWidget {
  const AgentActivityFeed({
    super.key,
    required this.chatId,
    this.leadingGap = true,
    this.answer,
  });

  /// The conversation whose live run this feed shows.
  final String chatId;

  final bool leadingGap;

  final Widget? answer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(agentRunProvider(chatId));
    final steps = run.steps;
    final sources = run.sources;
    final plan = run.plan;
    // How much of the working-out to show. At [AgentDetailMode.answer] the feed
    // is only the "Thinking…" line and whatever the answer cites — the user
    // asked not to be shown the machinery. The steps themselves are dropped by
    // [AgentTurnView], which owns that rule for a live turn and a saved one
    // alike; the plan is a different thing and follows it here.
    final detail = ref.watch(chatPrefsProvider.select((p) => p.detail));
    final showSteps = detail != AgentDetailMode.answer;
    // This feed only exists during an in-flight turn, so when nothing is
    // actively running the model is composing its next step. Show that, with a
    // live count, so a long pause reads as work rather than a stall.
    final thinking = steps.every(
      (step) => step.status != AgentActivityStatus.running,
    );
    final sections = <Widget>[
      if (run.parts.isNotEmpty || answer != null)
        AgentTurnView(parts: run.parts, trailing: answer),
      if (showSteps && plan.isNotEmpty) MessagePlan(entries: plan),
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
