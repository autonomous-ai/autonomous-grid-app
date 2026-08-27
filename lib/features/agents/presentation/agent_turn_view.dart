import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/code/code_highlight.dart';
import '../../../shared/copy/plural.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/code_text_scope.dart';
import '../../../shared/widgets/pulse.dart';
import '../../../shared/widgets/timeline_guide.dart';
import '../../playground/presentation/message_content.dart';
import '../logic/agent_run_fold.dart';
import '../logic/agent_sub_run.dart';
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
  const AgentTurnView({
    super.key,
    required this.parts,
    this.trailing,
    this.pending = const [],
  });

  /// The turn so far, oldest first.
  final List<TurnPart> parts;

  /// Drawn under the last part — the passage still streaming in, on a turn that
  /// hasn't landed yet. Null once it has.
  final Widget? trailing;

  /// What the user has said into this turn that hasn't been placed yet — see
  /// [AgentRun.pendingSaid]. Drawn under [trailing], which is where it will
  /// settle anyway: the seam it is waiting for closes the passage above it, so
  /// the row doesn't move when it lands, the text simply carries on below.
  ///
  /// Without this the message would be invisible from Send until the agent's
  /// next tool call — the composer clears, and nothing on screen says it went.
  final List<String> pending;

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
          else if (block case _Said(:final text))
            _SaidRow(text: text)
          // Dropped from the list rather than kept as an empty box: a
          // zero-height child still takes its separator, so hiding the steps
          // left a 10px hole where each block had been.
          else if (block case _Work(
            :final steps,
          ) when detail != AgentDetailMode.answer)
            // Keyed by the step it opens on, so what the reader has folded or
            // opened survives a passage landing above it — without one, the
            // block is matched by position and a new paragraph resets every
            // group in the turn.
            runIsFolded(steps.length)
                ? _FoldedRun(
                    key: ValueKey('run-${steps.first.id}'),
                    steps: steps,
                    detail: detail,
                  )
                : _StepColumn(
                    key: ValueKey('run-${steps.first.id}'),
                    steps: steps,
                    detail: detail,
                  ),
      ];
    }
    final blocks = [
      ..._blocks!,
      ?widget.trailing,
      for (final said in widget.pending) _SaidRow(text: said),
    ];
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

/// What the user said into the turn, drawn where they said it.
class _Said extends _Block {
  const _Said(this.text);

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
    // Grouped here rather than in the view, so the fold below counts and cuts
    // the same list the screen draws — a tail taken before grouping would open
    // on whichever row happened to be last in arrival order.
    blocks.add(_Work(List.unmodifiable(orderedBySubRun(running))));
    running = <AgentActivity>[];
  }

  for (final part in parts) {
    switch (part) {
      case TurnStep(:final step):
        running.add(step);
      case TurnText(:final text):
        flush();
        if (text.trim().isNotEmpty) blocks.add(_Prose(text));
      case TurnSaid(:final text):
        // Closes the run of steps before it for the same reason a passage does:
        // the user spoke *after* that work, and the rows above are what they
        // were watching when they did.
        flush();
        if (text.trim().isNotEmpty) blocks.add(_Said(text));
    }
  }
  flush();
  return blocks;
}

/// The step row's own geometry, and the guide's read off it.
///
/// [_stepIconSize] is the tool glyph; [_rowInsetLeft] is where a top-level row's
/// box starts. The trunk runs dead centre of the glyph — *derived*, not typed,
/// so moving either moves the line with it rather than leaving it pointing at
/// nothing (the same rule the rail's `_trunkX` follows).
const double _stepIconSize = 14;
const double _rowInsetLeft = 6;
const double _stepTrunkX = _rowInsetLeft + _stepIconSize / 2;

/// Where a sub-agent's row starts, and how far the arm reaches towards it.
///
/// The arm stops 2px short of the row's box for the reason the rail's does:
/// touching the hover fill makes the guide read as part of the row rather than
/// as the thing holding it.
const double _nestedInsetLeft = 22;
const double _stepArmLength = _nestedInsetLeft - _stepTrunkX - 2;

/// How wide a berth the trunk gives the tool glyph it runs through.
///
/// Half the glyph plus 4px of clearance, which is the margin the rail's own
/// node gap leaves around a folder icon — any tighter and the line reads as
/// striking the glyph out rather than passing behind it.
const double _stepNodeGap = _stepIconSize / 2 + 4;

/// The air above and below a step row.
///
/// Taller than a dense list wants, and that is the point: what is left of the
/// trunk between two nodes is the row's height less twice [_stepNodeGap], so at
/// the 4px this used to carry the line came out as 2px ticks either side of each
/// glyph — a dotted line, not a run. This leaves enough that the eye follows one
/// stroke from the first step to the last.
const double _rowInsetY = 7;

/// A long run of steps, folded to its tail until asked for.
///
/// The line above the rows says what is being left out, in both states: a fold
/// that quietly shows eight of two thousand steps is a fold that has lied about
/// what the assistant did.
class _FoldedRun extends StatefulWidget {
  const _FoldedRun({super.key, required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  State<_FoldedRun> createState() => _FoldedRunState();
}

class _FoldedRunState extends State<_FoldedRun> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    final shown = visibleRunSteps(steps.length, open: _open);
    // Not `length - shown`: a tail that opens on a nested row draws it branching
    // off nothing. See [runTailStart].
    final tail = steps.sublist(runTailStart(steps, shown));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _RunSummary(
          total: steps.length,
          shown: tail.length,
          open: _open,
          onTap: () => setState(() => _open = !_open),
        ),
        const SizedBox(height: 2),
        _StepColumn(steps: tail, detail: widget.detail),
      ],
    );
  }
}

/// The line over a folded run: how many steps ran, and how many of them are on
/// screen.
class _RunSummary extends StatelessWidget {
  const _RunSummary({
    required this.total,
    required this.shown,
    required this.open,
    required this.onTap,
  });

  final int total;
  final int shown;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      hoverColor: AppSurface.hoverFill,
      splashFactory: NoSplash.splashFactory,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Chevron(open: open, dim: true),
            const SizedBox(width: 6),
            Text(
              '$total ${plural(total, 'step')} · showing the last $shown',
              style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the user typed while the turn was running, drawn inside it.
///
/// The same bubble their messages wear in the transcript, a size down and on the
/// same side — so it reads as them speaking, here, without pretending to be a
/// turn of its own. Where it sits *is* the information: the agent's next
/// sentence is the answer to it.
class _SaidRow extends StatelessWidget {
  const _SaidRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        // Rule 1 again: no rim, depth from fill + shadow — `bubbleFill` alone is
        // all but invisible against the pane (see [ChatBubble]).
        color: AppGlass.bubbleFill,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(5),
        ),
        boxShadow: AppGlass.cardShadow,
      ),
      // The same renderer their own bubble uses, so a message typed mid-answer
      // reads exactly as it would have a turn later — and the turn's one
      // selection region still runs straight through it (see [MessageContent]).
      child: MessageContent(
        text: text,
        color: AppPalette.textPrimary,
        wrapSelection: false,
      ),
    ),
  );
}

/// A plain column of step rows — the shape shared by the short-block view and
/// the expanded long-block view.
///
/// **The guide line is what makes a run read as one.** Rows alone are four
/// facts that happen to be stacked; a line down their left edge is the thing
/// that says they are one stretch of work between two sentences, and it holds
/// even when the block runs past the height of the window.
///
/// Drawn with [AppPalette.guide], not [AppPalette.divider]: this is the same
/// device as the sidebar's project tree, down to sharing [TimelineGuide] with
/// it, and the token exists because a line the eye *follows* breaks into stray
/// ticks at a separator's weight. It is not a rim, so §0 rule 1 is untouched —
/// nothing here encloses a surface.
///
/// The line runs **through** each row's tool glyph rather than down the block's
/// left edge, so a step reads as a node on the run instead of an item in a
/// quoted list. Each row paints its own segment; [_StepRow] is told whether the
/// trunk arrives from above and carries on below, which is what stitches them
/// into one stroke without anything here measuring a row.
class _StepColumn extends StatefulWidget {
  const _StepColumn({super.key, required this.steps, required this.detail});

  final List<AgentActivity> steps;
  final AgentDetailMode detail;

  @override
  State<_StepColumn> createState() => _StepColumnState();
}

class _StepColumnState extends State<_StepColumn> {
  /// The groups the user has taken a decision about, by the id of the row that
  /// started each. A group that isn't in here follows its own run — see
  /// [_groupIsOpen].
  final _groups = <String, bool>{};

  /// Whether a sub-agent's steps are on screen.
  ///
  /// The default is the whole point, and it is not one state but two: **open
  /// while it works, folded once it has reported back**. A sub-agent runs for
  /// minutes with nothing else on screen to say the turn is alive, so hiding its
  /// steps then is hiding the only progress there is; afterwards those same rows
  /// are twenty lines of someone else's working-out sitting between the reader
  /// and the answer, and what they want from it is the one line saying how much
  /// there was.
  bool _groupIsOpen(SubRun run) => _groups[run.parentId] ?? !run.settled;

  @override
  Widget build(BuildContext context) {
    final runs = subRunsOf(widget.steps);
    final lines = <_Line>[];
    for (final step in widget.steps) {
      if (step.isNested) {
        final run = runs[step.parent];
        // Hidden with its group, not dropped: the fold above counts the whole
        // run, so a group folded here still says how many steps it stands for.
        if (run != null && !_groupIsOpen(run)) continue;
        lines.add(_StepLine(step, null));
        continue;
      }
      final run = runs[step.id];
      // Handed to the row only while the work is still going: once it has
      // reported back, the line under it is the summary, and a row still saying
      // "working…" beside it would be the screen contradicting itself.
      lines.add(_StepLine(step, run != null && run.settled ? null : run));
      // Only once it has finished. While it is working, the row above carries a
      // live line of its own and a second summary under it would say the same
      // thing twice.
      if (run != null && run.settled) {
        lines.add(_GroupLine(run, open: _groupIsOpen(run)));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      // Keyed by the step's own id: a folded block shows a *sliding window* of
      // the run when it was folded, so without a key Flutter matches rows by
      // position and a payload the user had opened slides onto whichever step
      // takes that slot next.
      children: [
        for (final (index, line) in lines.indexed)
          switch (line) {
            _StepLine(:final step, :final run) => _StepRow(
              key: ValueKey(step.id),
              step: step,
              run: run,
              detail: widget.detail,
              first: index == 0,
              last: index == lines.length - 1,
            ),
            _GroupLine(:final run, :final open) => _SubRunRow(
              key: ValueKey('group-${run.parentId}'),
              run: run,
              open: open,
              onTap: () => setState(() => _groups[run.parentId] = !open),
              first: index == 0,
              last: index == lines.length - 1,
            ),
          },
      ],
    );
  }
}

/// One drawn line of a step column: a step, or the summary standing in for a
/// sub-agent's folded group.
sealed class _Line {
  const _Line();
}

class _StepLine extends _Line {
  const _StepLine(this.step, this.run);

  final AgentActivity step;

  /// The work this row delegated, when it is the row that started a sub-agent.
  final SubRun? run;
}

class _GroupLine extends _Line {
  const _GroupLine(this.run, {required this.open});

  final SubRun run;
  final bool open;
}

/// The way back into a sub-agent's finished work: how many steps it ran, and a
/// chevron that puts them back on screen.
///
/// Stepped in to where its group's rows sit and branching off the same trunk, so
/// it reads as standing in for them rather than as a step of the agent's own.
/// It is chrome about rows, not a row — [AppPalette.textFaint] at the size the
/// run summary above the block already uses, which is what keeps a turn with
/// three sub-agents in it from reading as three more things that happened.
class _SubRunRow extends StatefulWidget {
  const _SubRunRow({
    super.key,
    required this.run,
    required this.open,
    required this.onTap,
    required this.first,
    required this.last,
  });

  final SubRun run;
  final bool open;
  final VoidCallback onTap;
  final bool first;
  final bool last;

  @override
  State<_SubRunRow> createState() => _SubRunRowState();
}

class _SubRunRowState extends State<_SubRunRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppCard.insetRadius);
    return TimelineGuide(
      role: TimelineRole.branch,
      trunkX: _stepTrunkX,
      nodeGap: _stepNodeGap,
      armLength: _stepArmLength,
      above: !widget.first,
      below: !widget.last,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onTap,
          // The row owns its own hover: the chevron is held back until the
          // pointer is on it, and a parent that tracked this for it would leave
          // the mark permanently dim.
          onHover: (value) => setState(() => _hovered = value),
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppSurface.hoverFill,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_nestedInsetLeft, 5, 6, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chevron(open: widget.open, dim: !_hovered && !widget.open),
                const SizedBox(width: 6),
                Text(
                  subRunSummary(widget.run),
                  style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
                ),
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
  const _StepRow({
    super.key,
    required this.step,
    required this.run,
    required this.detail,
    required this.first,
    required this.last,
  });

  final AgentActivity step;

  /// The sub-agent this row started, when it is a delegating row and that work
  /// is still going. Null on every ordinary step — and on a delegating row whose
  /// sub-agent has reported back, which is summarised under the row instead.
  final SubRun? run;

  final AgentDetailMode detail;

  /// Where this row sits in its run, which is all the guide line needs: the
  /// trunk arrives from above on every row but the first and carries on below
  /// on every row but the last. Passed in rather than worked out here — a row
  /// cannot see its siblings, and a line that guessed would dangle off both
  /// ends of every block.
  final bool first;
  final bool last;

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
    // By what the step *did*, not by which of the four kinds carried it. Kind
    // has only `tool` for everything that isn't a shell call, a web look-up or a
    // thought — so reading a file, editing one, searching, spawning a sub-agent
    // and every MCP call all drew the same wrench, and a column of eight rows
    // showed eight identical glyphs. The family is the one the summary line
    // counts with, so the icon and the words can't drift apart.
    final family = agentToolFamily(step);
    final icon = switch (family) {
      AgentToolFamily.read => LucideIcons.fileText300,
      AgentToolFamily.write => LucideIcons.filePlus300,
      AgentToolFamily.edit => LucideIcons.filePen300,
      AgentToolFamily.search => LucideIcons.search300,
      AgentToolFamily.list => LucideIcons.folder300,
      // The one glyph in this set with a box around it, and deliberately: a bare
      // `terminal` is a chevron and an underscore floating in space, which at
      // 14px and 300 weight reads as two stray marks rather than a mark. Shell
      // is also the one step that *runs* something on this computer, so the row
      // it is on being the one with a solid silhouette is the right emphasis.
      AgentToolFamily.shell => LucideIcons.squareTerminal300,
      AgentToolFamily.web => LucideIcons.globe300,
      AgentToolFamily.fetch => LucideIcons.link300,
      AgentToolFamily.subAgent => LucideIcons.listTree300,
      AgentToolFamily.todo => LucideIcons.listChecks300,
      // The glyphs the shell already files these under — Connectors is `cable`
      // in the sidebar and Skills is a sparkle — so a row in the transcript
      // points at the screen that manages the thing it just used.
      AgentToolFamily.mcp => LucideIcons.cable300,
      // The *singular* sparkle, where the nav row uses the plural at 18px.
      // Three stars of three sizes need the room: at the 14px a step row gives
      // them they close up into a smudge, and a smudge is not a mark. Same
      // family, so the two still read as the same thing.
      AgentToolFamily.skill => LucideIcons.sparkle300,
      AgentToolFamily.think => LucideIcons.brain300,
      AgentToolFamily.other => LucideIcons.wrench300,
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
    // What the sub-agent under this row is doing, while it is doing it. A second
    // line rather than more of the first: the row's own half is what the agent
    // asked for and does not change for minutes, and appending to it would push
    // the part that *is* changing off the end of the ellipsis.
    final run = widget.run;
    final progress = run == null ? '' : subRunProgress(run, widget.detail);
    final radius = BorderRadius.circular(AppCard.insetRadius);

    final row = Padding(
      // A sub-agent's step is stepped in under the `Agent` row that started it,
      // so a delegated file read reads as that agent's work rather than as the
      // main one's. The nesting is the only thing that says so — the rows are
      // otherwise identical, because the work is.
      padding: EdgeInsets.fromLTRB(
        step.isNested ? _nestedInsetLeft : _rowInsetLeft,
        _rowInsetY,
        6,
        _rowInsetY,
      ),
      child: Row(
        children: [
          _StepGlyph(icon: icon, status: step.status),
          const SizedBox(width: 8),
          // Title and subject share one line and one ellipsis budget: the title
          // is short and never gives way, the subject takes what is left.
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
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
                            // A command line is a string the user copies, which is
                            // the app's whole rule for mono (see [AppFont]) — and
                            // the one place in this row where `l`/`1` and `0`/`O`
                            // telling apart earns the slower read. Only the shell
                            // family: a query, a file path in prose or a tool's
                            // arguments are read, not pasted, and setting those in
                            // mono turns the transcript into a terminal.
                            //
                            // A point smaller than the sans beside it because mono
                            // sits optically larger at the same size; the payload
                            // wells below use the same figure.
                            fontFamily: family == AgentToolFamily.shell
                                ? AppFont.mono
                                : null,
                            fontFamilyFallback: family == AgentToolFamily.shell
                                ? AppFont.monoFallback
                                : null,
                            fontSize: family == AgentToolFamily.shell
                                ? 12.5
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                if (progress.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  // Secondary ink, not faint: this is the only line on screen
                  // reporting a wait that can run for minutes, and `textFaint`
                  // measures 3.33:1 light — under the floor §11 sets (the same
                  // call the subject half of the row above documents).
                  Text(
                    progress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.25,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
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
        // The trunk carries on below this row whenever there is anything left to
        // reach: another step, or this row's own opened payload. Without the
        // second half the line stopped dead at a row the user expanded, which
        // reads as the run having ended there.
        TimelineGuide(
          role: step.isNested ? TimelineRole.branch : TimelineRole.node,
          trunkX: _stepTrunkX,
          nodeGap: _stepNodeGap,
          armLength: _stepArmLength,
          above: !widget.first,
          below: !widget.last || _open,
          child: !canOpen
              ? row
              : Material(
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
        ),
        // Height animates so a long payload unrolls rather than jumping the
        // transcript out from under whatever the user was reading.
        AnimatedSize(
          duration: AppMotion.fold,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          // The trunk crosses the payload's band too — a line that stopped at
          // the row and picked up again under the payload would read as two
          // runs with a gap, which is what an opened step would look like from
          // across the transcript. Nothing to break around down here, so it
          // simply passes [TimelineRole.through].
          child: !_open
              ? const SizedBox(width: double.infinity)
              : TimelineGuide(
                  role: TimelineRole.through,
                  trunkX: _stepTrunkX,
                  below: !widget.last,
                  child: Padding(
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
        ),
      ],
    );
  }
}

/// The tool's glyph, carrying the step's outcome in its colour.
///
/// One mark, not two. A tick beside every row said only "this one worked", which
/// on a run where everything works is a column of identical green — and it cost
/// the glyph that says *what the step did* its place on the line the guide runs
/// through. Failure is the thing worth seeing, so it is the thing that changes
/// colour; success is the quiet default.
///
/// **Outcome is deliberately not in the colour.** A tick on every row said only
/// "this one worked", which on a run where everything works is a column of
/// identical green; and a red glyph turned an ordinary retry — an agent probing
/// a path, finding it missing, trying the next one — into a wall of alarm down a
/// turn that was going fine. What a step *is* survives being read at a glance;
/// how it went is a detail, and it keeps its place in the fold, where the
/// payload well is labelled `Error` and carries the reason.
///
/// [AppPalette.textSecondary], the same ink as the subject beside it: **6.0:1
/// light and 7.7:1 dark** against the transcript page, so the glyph clears the
/// *text* floor in both themes rather than the 3:1 an icon could have got away
/// with. The Material `onSurfaceVariant` this used to read resolves to these
/// exact two values (`#62615B` / `#A8A8A2`), so it is the same colour said in
/// the app's own vocabulary — and one that can't drift if the scheme is retuned
/// for something else. It also retires a real failure: the `unknown` branch drew
/// `textFaint`, which measures 3.33:1 in light and misses the floor outright.
///
/// A running step breathes instead: the row is a node on the guide line, so
/// swapping its glyph for a spinner would break the line at whichever row
/// happened to be live. Motion, not hue — the one signal a finished transcript
/// has no use for and a working one needs.
class _StepGlyph extends StatelessWidget {
  const _StepGlyph({required this.icon, required this.status});

  final IconData icon;
  final AgentActivityStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final glyph = Icon(
      icon,
      size: _stepIconSize,
      color: AppPalette.textSecondary,
    );
    if (status != AgentActivityStatus.running) return glyph;
    return Pulse(
      builder: (context, t, child) =>
          Opacity(opacity: 0.35 + 0.65 * t, child: child),
      child: glyph,
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
/// `#181818` — the composite is `#EDEDED` at **1.171:1** light and `#262626` at
/// **1.173:1** dark. The figures in the token's own doc (1.168 / 1.183) are
/// measured against a card, which is not this ground; the dark number here is
/// the same 1.173 the markdown code block ships at in the same place.
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
