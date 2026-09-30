/// What an agent ran while answering, folded under one line.
library;

import 'package:flutter/material.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_theme/grid_theme.dart';
import 'package:grid_theme/plural.dart';

/// How many of a running turn's steps show before the fold is opened.
///
/// The newest few, because that is the question somebody glancing at a phone
/// is asking — what is it doing *now* — and a turn that has read forty files
/// would otherwise push the answer off the screen.
const int _kLiveTail = 3;

/// A turn's steps, under a line that says how many.
///
/// Open with its newest [_kLiveTail] rows while the turn runs, folded shut once
/// it has finished: a finished answer is read for its words, and its steps are
/// there for whoever wants to check the work.
class StepFold extends StatefulWidget {
  const StepFold({
    required this.steps,
    required this.count,
    required this.live,
    super.key,
  });

  /// The newest steps the computer sent.
  final List<MobileStep> steps;

  /// How many the turn ran in all — more than [steps] on a long turn.
  final int count;

  /// Whether the turn is still running.
  final bool live;

  @override
  State<StepFold> createState() => _StepFoldState();
}

class _StepFoldState extends State<StepFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    final shown = _open
        ? steps
        : widget.live
        ? steps.sublist(steps.length - steps.length.clamp(0, _kLiveTail))
        : const <MobileStep>[];
    final hidden = widget.count - shown.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FoldLine(
            label: _summary(widget.count, live: widget.live),
            open: _open,
            onTap: () => setState(() => _open = !_open),
          ),
          if (_open && hidden > 0) _Earlier(hidden),
          for (final step in shown) _StepRow(step),
        ],
      ),
    );
  }

  String _summary(int count, {required bool live}) => live
      ? 'Working · $count ${plural(count, 'step')}'
      : 'Ran $count ${plural(count, 'step')}';
}

class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary);
    return Semantics(
      button: true,
      label: open ? 'Hide steps' : 'Show steps',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        child: ConstrainedBox(
          // A thumb, not a pointer: the line is the whole target.
          constraints: const BoxConstraints(minHeight: 36),
          child: Row(
            children: [
              Flexible(child: Text(label, style: style)),
              const SizedBox(width: 4),
              Icon(
                open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: AppPalette.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The steps before the ones sent, counted — a long turn is not sent whole.
class _Earlier extends StatelessWidget {
  const _Earlier(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$count earlier ${plural(count, 'step')} not shown',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint),
      ),
    );
  }
}

/// One step: how it went, what kind it was, and what it did.
class _StepRow extends StatelessWidget {
  const _StepRow(this.step);

  final MobileStep step;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final thinking = step.kind == MobileStepKind.thinking;
    return Padding(
      padding: EdgeInsets.only(left: step.nested ? 18 : 0, top: 3, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Center(child: _Outcome(step.status)),
          ),
          const SizedBox(width: 6),
          Icon(_glyph(step.kind), size: 14, color: AppPalette.textFaint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              step.label,
              maxLines: thinking ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: thinking
                  ? Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      fontStyle: FontStyle.italic,
                    )
                  : AppFont.codeStyle(color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  IconData _glyph(MobileStepKind kind) => switch (kind) {
    MobileStepKind.command => Icons.terminal_rounded,
    MobileStepKind.web => Icons.public_rounded,
    MobileStepKind.tool => Icons.handyman_outlined,
    MobileStepKind.thinking => Icons.psychology_outlined,
  };
}

/// Running, done, failed — or the turn ended before the step said.
class _Outcome extends StatelessWidget {
  const _Outcome(this.status);

  final MobileStepStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return switch (status) {
      MobileStepStatus.running => SizedBox.square(
        dimension: 11,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: AppPalette.textFaint,
        ),
      ),
      MobileStepStatus.done => Icon(
        Icons.check_rounded,
        size: 14,
        color: AppPalette.textFaint,
      ),
      MobileStepStatus.failed => Icon(
        Icons.close_rounded,
        size: 14,
        color: Theme.of(context).colorScheme.error,
      ),
      // Neither a tick nor a cross: the step never reported back, and either
      // mark would claim something nobody knows.
      MobileStepStatus.unknown => Icon(
        Icons.remove_rounded,
        size: 14,
        color: AppPalette.textFaint,
      ),
    };
  }
}
