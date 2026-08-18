import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/logic/turn_model_share.dart';
import '../../chat/logic/turn_model_usage.dart';
import '../../playground/logic/chat_message.dart';
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
    // The step the turn is waiting on, if any. The *last* running one: a step
    // that starts a sub-agent stays running while the work it delegated goes
    // on, so the newest is the one actually happening.
    AgentActivity? running;
    for (final step in steps) {
      if (step.status == AgentActivityStatus.running) running = step;
    }
    // A final copy so the null check below promotes it: `running` is assigned
    // in the loop above and so stays nullable to the analyzer.
    final active = running;
    final sections = <Widget>[
      if (run.parts.isNotEmpty || answer != null || run.pendingSaid.isNotEmpty)
        AgentTurnView(
          parts: run.parts,
          trailing: answer,
          pending: run.pendingSaid,
        ),
      if (showSteps && plan.isNotEmpty) MessagePlan(entries: plan),
      if (sources.isNotEmpty) MessageSources(sources: sources),
    ];
    // The status line carries its own gap and sits outside the separated run
    // above, because one of its two states draws nothing at all for the first
    // seconds of a step — and a zero-height section still takes its separator,
    // which would open and close an 8px hole under every bubble. The same trap
    // [AgentTurnView] documents for a hidden step block.
    final gap = sections.isEmpty && !leadingGap ? 0.0 : 8.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0 || leadingGap) SizedBox(height: i == 0 ? 10 : 8),
          sections[i],
        ],
        // The status line, and beside it what is answering.
        //
        // Something is running: its own row already says *what*, and nothing
        // says *for how long* — see [_StillWorkingRow], which stays out of the
        // way until the wait is long enough to be worth reporting. Nothing
        // running: the model is composing its next step, so say that with a
        // live count, reset each time the step list changes so it reads as time
        // since the last action rather than since the turn began.
        //
        // The models share this row rather than hanging off either state,
        // because the two swap as each tool call starts and ends — and
        // `_StillWorkingRow` draws nothing at all for the first seconds of a
        // step. Attached to one of them, the models blinked out for the length
        // of every step and came back between them. What is answering does not
        // stop being true while a command runs.
        Padding(
          padding: EdgeInsets.only(top: gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: active == null
                    ? _ThinkingRow(key: ValueKey(steps.length))
                    : _StillWorkingRow(
                        key: ValueKey(active.id),
                        step: active,
                        named: showSteps,
                        // The gap belongs to this row now, not the child.
                        gap: 0,
                      ),
              ),
              _LiveModels(chatId: chatId),
            ],
          ),
        ),
      ],
    );
  }
}

/// How long one step may run before the feed says so out loud.
///
/// Long enough that an ordinary step never trips it — a local command or a file
/// read is under a second — and short enough to arrive before the user starts
/// wondering.
///
/// **Six, down from twenty** (2026-08-17). Twenty was set against local work,
/// where the only steps that ran long were the ones a person expects to: a build,
/// a test suite. It misses the shape a grid turn actually has. Measured on the
/// weather turns in this machine's history, the agent's first *words* land after
/// six tool calls — every one of them a network fetch of ten to thirty seconds —
/// so the screen held a static list and a model caption for the better part of a
/// minute with nothing saying anything was alive. The user read that as stuck,
/// which is the exact bar the second sentence above sets and twenty seconds does
/// not clear.
///
/// Nothing else covers it. The model behind a grid turn emits **no reasoning
/// blocks at all** — not one `thinking` step appears across those transcripts —
/// so there is no inner monologue to print in the gap, and the agent's own
/// narration is the thing that arrives too late to fill it.
const Duration _quietRunNotice = Duration(seconds: 6);

/// The tools that hand the work to something else.
///
/// A step running one of these is not a command taking its time: the agent has
/// delegated, and what it delegated to writes its notes to *the agent*, not to
/// the user — the Claude stream parser drops that prose on purpose, because
/// folding it in left the reply switching voice mid-turn. So the screen can go
/// quiet for minutes with nothing but tool rows on it, which reads as broken. It
/// isn't; this row is what says so.
///
/// Measured, not imagined: a "review my codebase" turn handed the whole job to a
/// Skill and sat there for seven minutes showing nine finished commands and no
/// words at all. The agent was working the entire time.
const _delegatingTools = {'Task': 'sub-agent', 'Skill': 'skill'};

/// A step that has been running long enough to be worth a word.
///
/// Draws nothing at all until [_quietRunNotice] has passed, so a normal turn
/// never sees it. Past that it reports how long — and, when the agent has handed
/// the work to a skill or a sub-agent, *why* nothing is being said meanwhile.
class _StillWorkingRow extends StatefulWidget {
  const _StillWorkingRow({
    super.key,
    required this.step,
    required this.named,
    required this.gap,
  });

  final AgentActivity step;

  /// Whether the row may name what is running. False at
  /// [AgentDetailMode.answer], where the user asked not to be shown the
  /// machinery — the wait is still worth reporting, the mechanism isn't.
  final bool named;

  /// The space above the row — carried here rather than left to the feed,
  /// because the row spends its first seconds drawing nothing and a gap left
  /// behind by an invisible row is a hole that opens and closes on its own.
  final double gap;

  @override
  State<_StillWorkingRow> createState() => _StillWorkingRowState();
}

class _StillWorkingRowState extends State<_StillWorkingRow> {
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

  /// What the delegated work is called, or null when this step runs it itself.
  String? get _delegate =>
      widget.named ? _delegatingTools[widget.step.tool ?? ''] : null;

  @override
  Widget build(BuildContext context) {
    if (_seconds < _quietRunNotice.inSeconds) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final delegate = _delegate;
    final elapsed = _elapsedLabel(_seconds);
    final row = Padding(
      padding: EdgeInsets.fromLTRB(0, widget.gap + 3, 0, 3),
      child: Row(
        // Hug the text, like the thinking line beside it — at the default `max`
        // it filled the bubble and pushed the models to the far right edge.
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 8),
          Icon(
            Icons.hourglass_empty_rounded,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              delegate == null
                  ? 'Still working — $elapsed'
                  : 'A $delegate is doing this — $elapsed',
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
    if (delegate == null) return row;
    return Tooltip(
      message:
          'It works as its own assistant, so what it writes to itself is not '
          'shown here. The answer arrives when it finishes.',
      child: row,
    );
  }
}

/// Seconds as a person counts them: `45s`, `1m 05s`, `6m 48s`.
String _elapsedLabel(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '${minutes}m ${rest}s';
}

/// The "the model is composing its next step" line, shown in the feed while a
/// turn is in flight but nothing is running — a small spinner and the seconds
/// elapsed, so a pause between commands (long when the context is large) reads
/// as work in progress rather than a hang.
///
/// Its counterpart is [_StillWorkingRow], which covers the other half of the
/// same question: this one is the pause *between* steps, that one is a step
/// that has gone on too long to leave unexplained.
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
        // Hug the text. Left at the default `max` this filled the bubble and
        // pushed whatever followed it to the far right edge.
        mainAxisSize: MainAxisSize.min,
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

/// What is answering the open turn, beside the status line.
///
/// Under `auto` the composer's pill says "auto", which is a routing instruction
/// and not a model; on a task that runs for minutes this is the only place the
/// user can see which models the grid is actually spending.
class _LiveModels extends ConsumerWidget {
  const _LiveModels({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final shares = ref.watch(openTurnModelsProvider(chatId));
    final label = modelShareLabel(shares, label: modelShortLabel);
    if (label == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
