import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/transcript_event_row.dart';
import '../../playground/logic/chat_message.dart';
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
      // An open hand, not a pause: nothing is waiting to be resumed.
      GoalStatus.dormant => Icons.back_hand_outlined,
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

/// A turn the **app** sent on the user's behalf — the goal's next step, or one
/// beat of a repeating prompt — drawn as a quiet line instead of as their words.
///
/// It stays in the transcript because the agent really was told this, and the
/// answer under it reads as a non-sequitur without it. It is not a bubble
/// because nobody typed it: a message arriving in the user's own voice while
/// they sit and watch reads as the app having been taken over, which is the one
/// thing a chat that spends their tokens unattended must never look like (§5).
///
/// Tapping opens the prompt in full, so what was sent is one click away rather
/// than hidden — quiet is not the same as secret.
class AppSentTurnRow extends StatefulWidget {
  const AppSentTurnRow({super.key, required this.message});

  final ChatMessage message;

  @override
  State<AppSentTurnRow> createState() => _AppSentTurnRowState();
}

class _AppSentTurnRowState extends State<AppSentTurnRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    // The chevron below reads a palette token of its own, so this rebuilds on a
    // theme flip rather than leaving one mark in the old brightness.
    AppTheme.watch(context);
    final origin = widget.message.sentBy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TranscriptSideNote(
          icon: switch (origin) {
            TurnOrigin.loop => Icons.repeat_rounded,
            // The goal, and the arm nothing draws — both take the mark the goal
            // already wears elsewhere in the transcript, so the two surfaces
            // speak one vocabulary.
            TurnOrigin.goal || TurnOrigin.user => Icons.ads_click,
          },
          label: switch (origin) {
            TurnOrigin.goal => "Grid sent the goal's next step",
            TurnOrigin.loop => 'Grid sent the repeating prompt',
            // Never drawn: the row is only built for a turn the app sent.
            TurnOrigin.user => 'Grid sent this',
          },
          trailing: Icon(
            _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 14,
            color: AppPalette.textFaint,
          ),
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) _SentPrompt(text: widget.message.text),
      ],
    );
  }
}

/// The prompt the app sent, opened out under its line.
///
/// Selectable and recessed: it is a quotation of what went out, not something
/// said in the conversation, and a user who wants to know why the assistant did
/// what it did next needs to be able to copy it.
class _SentPrompt extends StatelessWidget {
  const _SentPrompt({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppSurface.recess,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SelectableText(
            text,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
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
