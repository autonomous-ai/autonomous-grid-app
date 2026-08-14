import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/code/code_highlight.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/code_text_scope.dart';
import '../../playground/presentation/message_content.dart';
import '../logic/agent_providers.dart';
import '../logic/agent_step_label.dart';

/// An agent turn drawn the way it happened: what it said, in the order it said
/// it, with the steps it ran sitting between the passages.
///
/// The chat used to draw a turn as "the whole answer, then every step under it".
/// That is the reverse of the truth — an agent narrates as it works, so the
/// sentence explaining a command was written *before* the command ran — and it
/// made a long turn unreadable: thirty rows of file reads between the answer and
/// the composer, with no way to tell which sentence any of them belonged to.
///
/// Used for both halves of a turn's life, which is what keeps them identical:
/// the live feed passes the run's parts as they arrive, the finished bubble
/// passes the same list off the saved message.
class AgentTurnView extends ConsumerStatefulWidget {
  const AgentTurnView({super.key, required this.parts, this.trailing});

  /// The turn so far, oldest first.
  final List<TurnPart> parts;

  /// Drawn under the last part — the passage still streaming in, on a turn that
  /// hasn't landed yet. Null once it has.
  final Widget? trailing;

  @override
  ConsumerState<AgentTurnView> createState() => _AgentTurnViewState();
}

class _AgentTurnViewState extends ConsumerState<AgentTurnView> {
  /// The settled part of the turn, built once and handed back **as the same
  /// widget instances** until the turn actually changes.
  ///
  /// This is load-bearing, not tidiness. On a live turn this widget rebuilds
  /// once per streamed token (its parent watches the send phase), and every
  /// passage in it is a `MessageContent` — which re-splits the text and re-parses
  /// the whole markdown into an AST on each build. A turn that has already
  /// written four paragraphs would re-parse all four, per token, for the rest of
  /// the turn. Identical child widgets make the framework skip the subtree
  /// outright, which is the same trick `TranscriptView` uses for committed turns
  /// and `_StreamingReply` for the passage still arriving.
  List<Widget>? _blocks;
  List<TurnPart>? _builtFrom;
  AgentDetailMode? _builtAt;
  Brightness? _brightness;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette.textPrimary for the prose — follow theme flips.
    final brightness = AppTheme.watch(context);
    // How much of the working-out to show. At [AgentDetailMode.answer] the steps
    // go entirely: the user asked to be shown the answer, not the machinery, and
    // that has to hold for a saved turn as much as for a live one.
    final detail = ref.watch(chatPrefsProvider.select((p) => p.detail));
    // The parts list is replaced, never mutated, so its identity is the change
    // signal. Brightness joins the key because the built passages carry the
    // palette they were made under.
    if (!identical(_builtFrom, widget.parts) ||
        _builtAt != detail ||
        _brightness != brightness) {
      _builtFrom = widget.parts;
      _builtAt = detail;
      _brightness = brightness;
      _blocks = [
        for (final block in _blocksOf(widget.parts))
          if (block case _Prose(:final text))
            MessageContent(
              text: text,
              color: AppPalette.textPrimary,
              // One selection region for the whole turn, opened below — a drag
              // has to run from the first paragraph to the last, across the
              // steps between them, the way it does on a plain reply.
              wrapSelection: false,
            )
          // Dropped from the list rather than kept as an empty box: a
          // zero-height child still takes its separator, so hiding the steps
          // left a 10px hole where each block had been.
          else if (block case _Work(
            :final steps,
          ) when detail != AgentDetailMode.answer)
            AgentStepList(steps: steps, detail: detail),
      ];
    }
    final blocks = [..._blocks!, ?widget.trailing];
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            blocks[i],
          ],
        ],
      ),
    );
  }
}

/// One drawn piece of a turn — a passage, or the steps that ran after it.
sealed class _Block {
  const _Block();
}

class _Prose extends _Block {
  const _Prose(this.text);

  final String text;
}

/// Steps that happened back to back with nothing said between them, drawn as one
/// block so a burst of thirty file reads folds behind a single summary instead
/// of thirty separate ones.
class _Work extends _Block {
  const _Work(this.steps);

  final List<AgentActivity> steps;
}

/// [parts] with consecutive steps gathered into one block each — the whole
/// layout decision, kept out of `build` because it is the part worth reading:
/// six file reads between two sentences are one piece of work, not six rows the
/// fold can't reach.
List<_Block> _blocksOf(List<TurnPart> parts) {
  final blocks = <_Block>[];
  var running = <AgentActivity>[];
  void flush() {
    if (running.isEmpty) return;
    blocks.add(_Work(List.unmodifiable(running)));
    running = <AgentActivity>[];
  }

  for (final part in parts) {
    switch (part) {
      case TurnStep(:final step):
        running.add(step);
      case TurnText(:final text):
        flush();
        if (text.trim().isNotEmpty) blocks.add(_Prose(text));
    }
  }
  flush();
  return blocks;
}

/// A block of steps: shown in full when there are few, or folded behind a
/// tappable summary of what the run did when there are many.
///
/// **Folded is one row.** Not one row and the last five — a fold that answers a
/// click by leaving five rows behind reads as a fold that didn't work, which is
/// exactly how it read. The summary line is the whole of it.
///
/// What changes with the run's state is the *default*, not what folding does:
/// open while the agent is still working, so the steps go by where they can be
/// watched; folded the moment the turn lands, so a finished turn is one line in
/// the transcript instead of forty. An explicit click always wins over both.
///
/// The choice is per block, and per run: this widget lives only as long as the
/// block it draws, so the next turn gets a fresh, default view rather than
/// inheriting the last one's.
class AgentStepList extends StatefulWidget {
  const AgentStepList({super.key, required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  State<AgentStepList> createState() => _AgentStepListState();
}

class _AgentStepListState extends State<AgentStepList> {
  /// The user's explicit open/closed choice, or null to follow the default
  /// (folded once the block is long).
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.length <= kFoldedStepLimit) {
      return _StepColumn(steps: steps, detail: widget.detail);
    }

    // Open while it works, folded once it is done — until the user says
    // otherwise, after which their choice stands for the life of this block.
    final live = aggregateActivityStatus(steps) == AgentActivityStatus.running;
    final expanded = _expanded ?? live;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepsHeader(
          steps: steps,
          expanded: expanded,
          onTap: () => setState(() => _expanded = !expanded),
        ),
        if (expanded) _StepColumn(steps: steps, detail: widget.detail),
      ],
    );
  }
}

/// A plain column of step rows — the shape shared by the short-block view and
/// the expanded long-block view.
class _StepColumn extends StatelessWidget {
  const _StepColumn({required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    // Keyed by the step's own id: a folded block shows a *sliding window* of the
    // run when it was folded, so without a key Flutter matches rows by
    // position and a payload the user had opened slides onto whichever step
    // takes that slot next.
    children: [
      for (final step in steps)
        _StepRow(key: ValueKey(step.id), step: step, detail: detail),
    ],
  );
}

/// The tappable summary row for a folded block: its overall status, what the run
/// did in words, and a chevron that flips as it opens.
class _StepsHeader extends StatelessWidget {
  const _StepsHeader({
    required this.steps,
    required this.expanded,
    required this.onTap,
  });

  final List<AgentActivity> steps;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Reads AppSurface.hoverFill from inside a lazy transcript — §0 rule 4.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppCard.insetRadius);
    // What the run did, not how many rows it has: standing in for the steps
    // while they are hidden, "8 steps" says only that something happened.
    final summary = describeStepRun(steps);
    return Semantics(
      button: true,
      label: expanded ? 'Hide steps' : 'Show all ${steps.length} steps',
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
                AgentStepStatusDot(status: aggregateActivityStatus(steps)),
                const SizedBox(width: 8),
                // A run that did five kinds of thing spells all five out, which
                // on a narrow window is longer than the column — it gives way
                // rather than overflowing (§4).
                Flexible(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: AppFont.medium,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _Chevron(open: expanded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The disclosure marker shared by the group summary and each step row — a
/// quarter turn at the app's hover speed, so a row that opens and a group that
/// opens move the same way.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.open, this.dim = false});

  final bool open;

  /// Held back until the row is hovered: a column of steps with a chevron
  /// blazing on every row reads as eight controls rather than eight facts.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedOpacity(
      opacity: dim ? 0 : 1,
      duration: AppMotion.hover,
      child: AnimatedRotation(
        turns: open ? 0.25 : 0,
        duration: AppMotion.hover,
        curve: AppMotion.curve,
        child: Icon(
          LucideIcons.chevronRight300,
          size: 13,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}

/// One step in a block: a status mark, what kind of thing it was, what it was
/// about — and, when the agent's transport carried them, the call and what came
/// back, behind a fold.
///
/// A row, not a card with a fill of its own. A turn runs dozens of these and
/// eight stacked surfaces inside one answer would read as eight separate
/// things; the fill is spent on the payload instead, which is the part that
/// needs to be told apart from the prose around it.
class _StepRow extends StatefulWidget {
  const _StepRow({super.key, required this.step, required this.detail});

  final AgentActivity step;
  final AgentDetailMode detail;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow> {
  bool _open = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppSurface from inside a lazy transcript — watch here or
    // the row keeps the palette it was first painted with.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final step = widget.step;
    final icon = switch (step.kind) {
      AgentActivityKind.command => Icons.terminal,
      AgentActivityKind.web => Icons.public,
      AgentActivityKind.tool => Icons.build_outlined,
      AgentActivityKind.thinking => Icons.psychology_outlined,
    };
    // A thought's whole text *is* its payload — it has no arguments, and the
    // label would otherwise be a paragraph clipped into one line.
    final thought = step.kind == AgentActivityKind.thinking
        ? step.label.trim()
        : '';
    final canOpen =
        widget.detail == AgentDetailMode.stepsCommands &&
        (step.hasPayload || thought.isNotEmpty);
    // The two quieter levels keep the wording they were written for — "Ran rg",
    // "Searched the web" — because that is what the setting *means*: the same
    // steps said without the shell. Only the detailed level gets the two-ink
    // row, where naming the tool is the point.
    final title = widget.detail == AgentDetailMode.stepsCommands
        ? agentStepTitle(step)
        : agentStepLabel(step, widget.detail);
    final about = agentStepDetail(step, widget.detail);
    // A running row ends in an ellipsis, so it reads as something happening even
    // where the spinner is off screen or the reader isn't looking at it.
    final trailing = step.status == AgentActivityStatus.running ? '…' : '';
    final radius = BorderRadius.circular(AppCard.insetRadius);

    final row = Padding(
      // A sub-agent's step is stepped in under the `Agent` row that started it,
      // so a delegated file read reads as that agent's work rather than as the
      // main one's. The nesting is the only thing that says so — the rows are
      // otherwise identical, because the work is.
      padding: EdgeInsets.fromLTRB(step.isNested ? 22 : 6, 4, 6, 4),
      child: Row(
        children: [
          AgentStepStatusDot(status: step.status),
          const SizedBox(width: 8),
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          // Title and subject share one line and one ellipsis budget: the title
          // is short and never gives way, the subject takes what is left.
          Flexible(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                // Both halves stay above the 4.5:1 floor (§11), computed on the
                // transcript page: textPrimary 17.4:1 light / 18.2:1 dark,
                // textSecondary 6.2:1 / 8.3:1. The subject — the command, the
                // path, the query — is the *informative* half of the row and was
                // drawn in textFaint, which measures 3.33:1 light and 3.86:1
                // dark and fails. The hierarchy is carried by weight and by
                // primary-against-secondary ink instead.
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textPrimary,
                  fontWeight: AppFont.medium,
                ),
                children: [
                  TextSpan(text: about.isEmpty ? '$title$trailing' : title),
                  if (about.isNotEmpty)
                    TextSpan(
                      text: '  $about$trailing',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: AppFont.regular,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (canOpen) ...[
            const SizedBox(width: 6),
            _Chevron(open: _open, dim: !_hovered && !_open),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!canOpen)
          row
        else
          Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: () => setState(() => _open = !_open),
              onHover: (value) => setState(() => _hovered = value),
              splashFactory: NoSplash.splashFactory,
              hoverColor: AppSurface.hoverFill,
              child: row,
            ),
          ),
        // Height animates so a long payload unrolls rather than jumping the
        // transcript out from under whatever the user was reading.
        AnimatedSize(
          duration: AppMotion.fold,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 0, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (thought.isNotEmpty)
                        _PayloadWell(label: 'Thought', text: thought)
                      else ...[
                        if (step.request case final request?)
                          _PayloadWell(
                            label: 'Request',
                            text: request,
                            // A shell step's request is the command line; every
                            // other tool's is the arguments object the agent
                            // sent. Both are read faster in the transcript's own
                            // code colours.
                            code: step.kind == AgentActivityKind.command
                                ? 'bash'
                                : (request.startsWith('{') ? 'json' : ''),
                          ),
                        if (step.result case final result?) ...[
                          if (step.request != null) const SizedBox(height: 4),
                          _PayloadWell(
                            label: step.status == AgentActivityStatus.failed
                                ? 'Error'
                                : 'Result',
                            text: result,
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// What a tool was asked to do, or what it answered: a recessed well holding the
/// text as it came, in the app's code face.
///
/// A well rather than a card, and no rim (§0 rule 1): this sits *inside* an
/// answer, so it has to read as carved into the turn rather than floating over
/// it — the same call the markdown code block makes.
///
/// [AppSurface.wellFill] is an overlay, so it separates from whatever it lands
/// on instead of being picked against one resting colour. Computed for where it
/// actually lands — the transcript page, `AppPalette.windowBg` `#FFFFFF` /
/// `#0A0A0A` — the composite is `#EDEDED` at **1.171:1** light and `#181818` at
/// **1.115:1** dark. The figures in the token's own doc (1.168 / 1.183) are
/// measured against a card, which is not this ground; the dark number here is
/// the same 1.115 the markdown code block ships at in the same place.
///
/// The text on it is measured too: `textPrimary` reads 14.9:1 light / 16.3:1
/// dark, `textSecondary` (the label) 5.3:1 / 7.4:1 — both clear of the 4.5:1
/// floor. `textFaint` would not (2.85:1 / 3.46:1), which is why it is nowhere in
/// here.
class _PayloadWell extends StatelessWidget {
  const _PayloadWell({required this.label, required this.text, this.code = ''});

  final String label;
  final String text;

  /// The language to colour [text] as, or empty to leave it plain — a tool's
  /// arguments arrive as JSON and a shell step as a command line, and both are
  /// read far faster with the same colours the transcript's code blocks use. A
  /// result is left plain: it is output, not source, and colouring a build log
  /// as if it were code invents structure that isn't there.
  final String code;

  @override
  Widget build(BuildContext context) {
    final brightness = AppTheme.watch(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppSurface.wellFill,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Chrome, so it keeps the UI scale rather than the code one.
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          // Code scrolls sideways rather than wrapping: a command line broken
          // across three lines is a command line nobody can read back. Prose
          // must wrap — a thought is paragraphs, and one horizontal line per
          // paragraph is unreadable at any width.
          //
          // Plain `Text`, not `SelectableText`: the latter is an `EditableText`
          // with its own focus node and cursor ticker, and a long turn holds
          // dozens of these. The selection region is the turn's, opened once in
          // `AgentTurnView` — the same call `MessageContent` documents at length.
          CodeTextScope(
            child: code.isEmpty
                ? _PayloadText(text: text, code: code, brightness: brightness)
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _PayloadText(
                      text: text,
                      code: code,
                      brightness: brightness,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The payload itself — coloured by the app's own highlighter when it is source
/// the highlighter knows, plain otherwise.
///
/// Split out so the colouring runs against a settled string: [CodeHighlight]
/// memoises by (code, language, brightness, style), and calling it from a build
/// that also lays the well out keeps that cache honest.
class _PayloadText extends StatelessWidget {
  const _PayloadText({
    required this.text,
    required this.code,
    required this.brightness,
  });

  final String text;
  final String code;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette.textPrimary and the code face — §0 rule 4.
    AppTheme.watch(context);
    final base = AppFont.codeStyle(color: AppPalette.textPrimary, height: 1.45);
    final spans = code.isEmpty
        ? null
        : CodeHighlight.spans(
            code: text,
            language: code,
            base: base,
            brightness: brightness,
          );
    return spans == null
        ? Text(text, style: base)
        : Text.rich(spans, style: base);
  }
}

/// A per-step status glyph: a spinner while running, a check when done, an
/// error mark when it failed.
class AgentStepStatusDot extends StatelessWidget {
  const AgentStepStatusDot({super.key, required this.status});

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
      // Neither a tick nor an error mark: the step never said how it went, and
      // an outline circle is the shape of that — visibly *not* the check beside
      // it, without accusing anything. See [AgentActivityStatus.unknown].
      case AgentActivityStatus.unknown:
        return Icon(
          Icons.circle_outlined,
          size: 13,
          color: AppPalette.textFaint,
        );
    }
  }
}
