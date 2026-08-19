import 'package:flutter/material.dart';

import '../../../shared/widgets/transcript_event_row.dart';
import '../logic/commands/chat_compaction.dart';
import '../logic/commands/chat_goal.dart';
import '../logic/commands/chat_loop.dart';

/// Where `/compact` folded the context up.
///
/// The messages above it are still there to read; this is the line that says
/// the assistant is reading a summary of them instead.
class CompactedRow extends StatelessWidget {
  const CompactedRow({super.key, required this.compaction});

  final ChatCompaction compaction;

  @override
  Widget build(BuildContext context) => TranscriptEventRow(
    icon: Icons.unfold_less_rounded,
    label: compactedDividerLabel(compaction),
  );
}

/// How the goal ended, at the turn it ended on.
///
/// Met, judged impossible, and stalled are three different pieces of news and
/// each gets its own word and its own mark — one word for all three is the bug
/// that shipped as issue #33 (§5).
class GoalEndedRow extends StatelessWidget {
  const GoalEndedRow({super.key, required this.goal});

  final ChatGoal goal;

  @override
  Widget build(BuildContext context) => TranscriptSideNote(
    icon: switch (goal.status) {
      GoalStatus.active => Icons.ads_click,
      GoalStatus.met => Icons.check_circle_outline_rounded,
      GoalStatus.impossible => Icons.error_outline_rounded,
      GoalStatus.stalled ||
      GoalStatus.paused => Icons.pause_circle_outline_rounded,
      GoalStatus.blocked => Icons.block_rounded,
      // A limit reached is not a failure — the hourglass says "later", where
      // the error mark would say "never".
      GoalStatus.usageLimited ||
      GoalStatus.budgetLimited => Icons.hourglass_empty_rounded,
    },
    label: goalEndedNote(goal),
  );
}

/// The mark on the turn that handed a goal over.
///
/// Right-aligned under the user's own message, because that is whose act it
/// was. It is said once, at the turn it happened, and never again — the strip
/// above the composer is what says a goal is *still* running.
class GoalSentBadge extends StatelessWidget {
  const GoalSentBadge({super.key});

  @override
  Widget build(BuildContext context) => const TranscriptSideNote(
    icon: Icons.ads_click,
    label: 'Sent as goal',
    alignment: Alignment.centerRight,
  );
}

/// Where the repeating prompt stopped — because the assistant reached the end
/// of the job, because the user stopped it, or because its seven days ran out.
class LoopEndedRow extends StatelessWidget {
  const LoopEndedRow({super.key, required this.loop});

  final ChatLoop loop;

  @override
  Widget build(BuildContext context) => TranscriptEventRow(
    icon: switch (loop.status) {
      LoopStatus.running => Icons.repeat_rounded,
      LoopStatus.stopped => Icons.pause_circle_outline_rounded,
      LoopStatus.finished => Icons.task_alt_rounded,
      LoopStatus.expired => Icons.hourglass_empty_rounded,
    },
    label: loopBarLabel(loop, DateTime.now()),
  );
}
