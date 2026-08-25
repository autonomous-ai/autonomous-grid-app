import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/composer_trigger.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../chat/logic/chat_scope.dart';
import '../logic/active_chat_agent.dart';
import '../logic/agent_catalog.dart';
import '../logic/auto_agent.dart';
import '../logic/auto_agent_router.dart';
import 'agent_mark.dart';
import '../logic/agent_grid_support.dart';
import '../logic/agent_status.dart';

/// The composer's control for **which agent** answers the chat — the other half
/// of "what happens when I press Send", sitting next to the model it runs.
///
/// Lists the agents installed on this computer; the one in force wears a tick.
/// Picking one saves it where the chat lives — on its **project** when it has
/// one, else as the app's standing choice (see [ChatScopePrefs]) — and the menu
/// says which, so a pick that follows you between projects is never a surprise.
/// An agent this grid can't run is offered but marked, so the choice is honest
/// rather than silently handed back (the handover bar explains the swap). Shown
/// only when an agent is the one answering (the composer gates it on that).
///
/// **Only until the chat starts.** From its first message a chat is a session
/// one agent is holding — a CLI with a conversation in it, or an ACP connection
/// — and the pill stops being a menu and becomes the name of who is answering
/// ([chatAgentLockedProvider]). Handing a session over mid-conversation was
/// never something this menu could do: the transcript stayed and the
/// conversation behind it did not, because the new agent has never read a word
/// of it. The way to another agent is a new chat, which is the gesture that
/// actually produces one.
class AgentPicker extends ConsumerStatefulWidget {
  const AgentPicker({super.key});

  @override
  ConsumerState<AgentPicker> createState() => _AgentPickerState();
}

const _menuWidth = 260.0;
const _rowGutter = 8.0;
const _rowInnerPad = 10.0;
final _rowRadius = BorderRadius.circular(AppControl.radius);

/// The rest of a row's box, spelled out because [_menuSize] measures the text
/// inside it: the gutter above and below a row, its own padding, the mark and the
/// gap after it, and the tick column with the gap before it.
const _rowOuterPadV = 3.0;
const _rowInnerPadV = 8.0;
const _rowTrailPad = 8.0;
const _markSize = 20.0;
const _markGap = 10.0;
const _tickGap = 8.0;
const _tickSize = 16.0;
const _titleSubtitleGap = 1.0;

/// A subtitle never runs past two lines — the row is a glance, not a paragraph.
/// The painter is held to the same limit, or it would measure a height the row
/// then ellipsises away.
const _subtitleMaxLines = 2;

/// The scope note's own air, above and below its one sentence.
const _scopeNotePadTop = 6.0;
const _scopeNotePadBottom = 4.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`, read off
/// that style rather than guessed. Same note in `grid_model_picker`: the two
/// drifting apart is what pushes a menu off its button.
const _menuPadding = 5.0;

/// The air the panel keeps from the window edge, passed to
/// [anchoredMenuPosition] and used to work out how tall it may draw.
const _menuMargin = 8.0;

/// The width a row's text wraps inside — the panel, less every fixed box beside
/// it. The tick column counts whether or not this row wears one: [_MenuRow]
/// keeps the space either way, so picking a different agent can't reflow the
/// list under the cursor.
const _rowTextWidth =
    _menuWidth -
    _rowGutter * 2 -
    _rowInnerPad -
    _rowTrailPad -
    _markSize -
    _markGap -
    _tickGap -
    _tickSize;

/// The width the scope note wraps inside — its own padding, not a row's.
const _scopeNoteWidth = _menuWidth - (_rowGutter + _rowInnerPad) * 2;

/// One line of the menu, as both the thing that draws and the thing that gets
/// measured. `tool` is null for the Auto row.
typedef _Entry = ({AgentTool? tool, String title, String subtitle, bool warn});

/// The tallest this panel may draw: the window, less the margin it keeps at both
/// edges.
///
/// Its own cap rather than [AppControl.menuMaxHeight]'s 240, because this list is
/// not something to scroll through — it is the agents installed on this computer,
/// four of them at most, and at 240 the panel drew two and a half of them. The
/// half-drawn row reads as a list that lost its tail rather than one to drag, and
/// the line naming where the pick is saved sat below the fold — the one thing in
/// this menu a user can't work out from the rows themselves.
double _menuMaxHeight(BuildContext context) =>
    MediaQuery.sizeOf(context).height - _menuMargin * 2;

/// What the menu will measure, so [anchoredMenuPosition] lands the panel on the
/// pill rather than near it.
///
/// The alternative — `MenuStyle.alignment` plus an `alignmentOffset` — reads as
/// "put the menu's top-left on the pill's top-left and grow *down*", which sends
/// a tall panel through the composer; Flutter then shoves it up and sideways to
/// fit the window, and where it lands is the clamp's choice, not the pill's.
/// That is what drifted this menu ~20px left of the pill it belongs to. See the
/// same note in `grid_model_picker`.
///
/// Measured off the strings the rows are about to draw, not guessed at a flat
/// height per row: a tagline and an "agent can't run here" note wrap to different
/// numbers of lines, and neither is the height it is at whatever font size the OS
/// is set to. This replaced three constants — 40 for a row, 64 for one carrying a
/// note, 56 for Auto — that only ever agreed with the rows by luck, and were
/// covered for by the 240 cap clamping estimate and panel to the same number.
Size _menuSize(
  BuildContext context, {
  required List<_Entry> entries,
  required String scopeNote,
}) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final title = _titleStyle(theme);
  final subtitle = _subtitleStyle(theme, warn: false);

  var height =
      _menuPadding * 2 +
      _scopeNotePadTop +
      _scopeNotePadBottom +
      _textHeight(scopeNote, _scopeNoteStyle(theme), _scopeNoteWidth, scaler);
  for (final entry in entries) {
    final text =
        _textHeight(entry.title, title, _rowTextWidth, scaler, maxLines: 1) +
        _titleSubtitleGap +
        _textHeight(
          entry.subtitle,
          subtitle,
          _rowTextWidth,
          scaler,
          maxLines: _subtitleMaxLines,
        );
    height += _rowOuterPadV * 2 + _rowInnerPadV * 2 + math.max(_markSize, text);
  }
  return Size(_menuWidth, height);
}

/// The row's two type styles, and the scope note's, resolved off the theme so
/// that what [_menuSize] lays out and what [_MenuRow] draws are the same string
/// in the same font.
///
/// A bare `TextStyle` would *inherit* the ambient default, so the measured copy
/// would carry a different family and tracking than the drawn copy and wrap
/// somewhere else — a 6px error on one line in the approval menu, and this menu
/// has five.
TextStyle _titleStyle(ThemeData theme) => theme.textTheme.bodyMedium!.copyWith(
  color: AppPalette.textPrimary,
  fontSize: 13,
  fontWeight: AppFont.medium,
  height: 1.2,
  letterSpacing: AppFont.trackingFor(13),
);

TextStyle _subtitleStyle(ThemeData theme, {required bool warn}) =>
    theme.textTheme.bodySmall!.copyWith(
      color: warn ? AppPalette.warn : AppPalette.textSecondary,
      fontSize: 11.5,
      height: 1.25,
      letterSpacing: AppFont.trackingFor(11.5),
    );

TextStyle _scopeNoteStyle(ThemeData theme) =>
    theme.textTheme.bodySmall!.copyWith(
      color: AppPalette.textFaint,
      fontSize: 11,
      height: 1.3,
      letterSpacing: AppFont.trackingFor(11),
    );

/// Where the pick will be remembered, in one sentence — shared with [_ScopeNote]
/// so the line that places the panel is the line that draws in it.
String scopeNoteText(String? projectName) => projectName == null
    ? 'Saved for chats outside a project. Each project keeps its own.'
    : 'Saved for $projectName. Your other projects keep theirs.';

/// What a line box of [text] occupies at [style], laid out in [maxWidth].
double _textHeight(
  String text,
  TextStyle style,
  double maxWidth,
  TextScaler scaler, {
  int? maxLines,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  return painter.height;
}

class _AgentPickerState extends ConsumerState<AgentPicker> {
  final _menu = MenuController();

  void _select(AgentTool tool) {
    ref.read(chatScopePrefsProvider).setAgent(tool.id);
    _menu.close();
  }

  /// Pick Auto: the grid chooses which installed assistant answers each
  /// question. Stored like any other agent choice — a sentinel id in the same
  /// slot — so a project keeps its own, and the model it runs on is decided at
  /// send time (the grid's auto model).
  void _selectAuto() {
    ref.read(chatScopePrefsProvider).setAgent(kAutoAgentId);
    _menu.close();
  }

  /// The trigger's tooltip.
  ///
  /// Under Auto it names no agent. It used to add "(now: …)" from
  /// [activeChatAgentProvider], which under Auto is only the fallback that
  /// resolves an unknown id — it would say "now: Hermes" and then Codex would
  /// answer the coding question. There is no agent answering *between* turns
  /// either: the pick is made per send, and the reply's own footer names who
  /// made it.
  String _triggerTooltip(bool autoChosen, AgentTool active, String? project) {
    if (autoChosen) {
      final where = project == null ? '' : ' in $project';
      return 'Auto$where · the grid picks the best assistant for each question';
    }
    return project == null
        ? 'Which agent answers · ${active.name}'
        : 'Which agent answers in $project · ${active.name}';
  }

  /// Why [tool] can't answer on the open grid, or null when it can.
  ///
  /// Two different walls, said apart: the grid answers no dialect this agent
  /// speaks at all, or it does but serves nothing this agent can be pointed at
  /// (a grid of `claude:*` models with Codex in force). One wording for both
  /// would send a user hunting for the wrong fix — the second clears the moment
  /// they pick another model, the first only on another grid.
  String? _unavailableNote(AgentTool tool) {
    if (!ref.watch(agentRunsOnGridProvider(tool))) {
      return 'Not available on this grid — pick borrows chat until a grid '
          'that runs it.';
    }
    if (!ref.watch(agentHasModelHereProvider(tool))) {
      return 'No model on this grid it can answer with.';
    }
    return null;
  }

  /// The trigger's tooltip once the chat has fixed its agent — a fact, and the
  /// reason it is one, so a pill that no longer opens doesn't read as broken.
  String _lockedTooltip(bool autoChosen, AgentTool active) => autoChosen
      ? 'Auto answers this chat · the grid picks the best assistant for each '
            'question'
      : '${active.name} answers this chat · an agent is fixed when the chat '
            'starts. Start a new chat to use another.';

  @override
  Widget build(BuildContext context) {
    // `appMenuStyle` reads palette tokens; follow theme flips.
    AppTheme.watch(context);
    final active = ref.watch(activeChatAgentProvider);
    final autoChosen = ref.watch(isAutoAgentChosenProvider);
    // A chat under way names its agent and offers nothing. Returned before the
    // list is built at all: the rows, their notes and the panel's measured size
    // are all work for a menu that cannot open.
    if (ref.watch(chatAgentLockedProvider)) {
      return _AgentTrigger(
        active: active,
        autoChosen: autoChosen,
        tooltip: _lockedTooltip(autoChosen, active),
        onTap: null,
      );
    }
    final installed = [
      for (final tool in AgentTool.values)
        if (ref.watch(agentInstalledProvider(tool))) tool,
    ];
    // Auto is offered only in a developer build ([autoAgentIsOffered]), and
    // only when there's a real choice to make — two or more installed agents.
    // With one, "let the grid pick" would always pick it, so the row would be a
    // longer way to say what a single agent already says.
    final offerAuto = autoAgentIsOffered && installed.length > 1;
    // Where the pick will be remembered, said out loud: in a project the choice
    // is that project's and changes nothing anywhere else, which is the whole
    // point of it — and it explains why the agent changed when they switched.
    final project = ref.watch(openChatProjectProvider);
    final notes = [for (final tool in installed) _unavailableNote(tool)];
    // One list, read twice: the rows are built from it and the panel is measured
    // from it. Two lists — one of widgets, one of heights — is how a menu comes to
    // be placed for a shape it isn't drawing.
    final entries = <_Entry>[
      if (offerAuto)
        (tool: null, title: 'Auto', subtitle: kAutoAgentTagline, warn: false),
      for (final (index, tool) in installed.indexed)
        (
          tool: tool,
          title: tool.name,
          subtitle: notes[index] ?? tool.tagline,
          warn: notes[index] != null,
        ),
    ];
    final scopeNote = scopeNoteText(project?.name);
    return MenuAnchor(
      controller: _menu,
      // The shared recipe, not a hand-rolled one. This carried its own
      // `AppPalette.cardBg` at elevation 8 / radius 14: cardBg is picked to be
      // read *on the page*, so as a panel floating over the composer it had no
      // edge, and its lift disagreed with every other menu in the app.
      // …with its 240 cap lifted: see [_menuMaxHeight] for why this list is
      // shown whole rather than scrolled.
      style: appMenuStyle().copyWith(
        maximumSize: WidgetStatePropertyAll(
          Size.fromHeight(_menuMaxHeight(context)),
        ),
      ),
      menuChildren: [
        for (final entry in entries)
          switch (entry.tool) {
            null => _AutoItem(selected: autoChosen, onTap: _selectAuto),
            final tool => _AgentItem(
              tool: tool,
              subtitle: entry.subtitle,
              warn: entry.warn,
              // A concrete agent is ticked only when it's the *chosen* one —
              // under Auto the choice is Auto, and ticking an agent as well
              // would show two ticks and hide that the grid picks a fresh one
              // per question.
              selected: !autoChosen && tool == active,
              onTap: () => _select(tool),
            ),
          },
        _ScopeNote(note: scopeNote),
      ],
      builder: (context, controller, _) => _AgentTrigger(
        active: active,
        autoChosen: autoChosen,
        tooltip: _triggerTooltip(autoChosen, active, project?.name),
        onTap: () => controller.isOpen
            ? controller.close()
            : controller.open(
                // Positioned, not aligned — see [_menuSize] for why.
                position: anchoredMenuPosition(
                  context,
                  menuSize: _menuSize(
                    context,
                    entries: entries,
                    scopeNote: scopeNote,
                  ),
                  margin: _menuMargin,
                  gap: AppControl.menuGap,
                  // The pill sits at the bottom of the window, so the menu opens
                  // upward; `anchoredMenuPosition` drops back below if it won't fit.
                  preferAbove: true,
                  // The same cap the panel is drawn with above — placement sums
                  // the height the panel is about to take, so the two clamping to
                  // different numbers is what lifts a menu clear of its button.
                  maxHeight: _menuMaxHeight(context),
                ),
              ),
      ),
    );
  }
}

/// The pill itself: the agent's mark, its name, and a caret only while there is
/// a menu behind it.
///
/// One widget for both states so the locked pill and the menu's trigger can't
/// drift apart in mark, label or width — the two sit in the same slot, and a
/// chat that starts must not resize the composer's toolbar under the cursor.
class _AgentTrigger extends StatelessWidget {
  const _AgentTrigger({
    required this.active,
    required this.autoChosen,
    required this.tooltip,
    required this.onTap,
  });

  /// The agent answering, drawn even under Auto — where the label is "Auto"
  /// instead, because under Auto nobody is answering *between* turns.
  final AgentTool active;
  final bool autoChosen;
  final String tooltip;

  /// Opens the menu, or null once this chat has fixed its agent.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Reads `AppPalette.accent`; a token is resolved at paint time and follows
    // no ancestor's watch.
    AppTheme.watch(context);
    return ComposerTrigger(
      label: autoChosen ? 'Auto' : active.name,
      tooltip: tooltip,
      leading: autoChosen
          ? Icon(Icons.auto_awesome, size: 14, color: AppPalette.accent)
          : AgentMark(tool: active, size: 14),
      onTap: onTap,
    );
  }
}

/// The line under the list that says who the pick belongs to: this project, or
/// every chat outside one.
///
/// One sentence, in the user's terms — "your other projects keep theirs" is the
/// fact that stops a per-project setting reading as an app-wide one that keeps
/// changing itself.
class _ScopeNote extends StatelessWidget {
  const _ScopeNote({required this.note});

  /// The sentence itself, handed in rather than composed here: [_menuSize] lays
  /// out this exact string to place the panel — see [scopeNoteText].
  final String note;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _rowGutter + _rowInnerPad,
        _scopeNotePadTop,
        _rowGutter + _rowInnerPad,
        _scopeNotePadBottom,
      ),
      child: SizedBox(
        width: _scopeNoteWidth,
        child: Text(note, style: _scopeNoteStyle(Theme.of(context))),
      ),
    );
  }
}

/// The Auto row at the top of the list: a wand, the word "Auto", and the line
/// that says what it does. The same box as an agent row, so it reads as a peer
/// of the agents it chooses between, not a setting bolted above them.
class _AutoItem extends StatelessWidget {
  const _AutoItem({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return _MenuRow(
      // A 20px box like AgentMark, so the wand lines up with the agent icons
      // under it rather than sitting a few pixels off.
      leading: SizedBox(
        width: 20,
        height: 20,
        child: Icon(Icons.auto_awesome, size: 18, color: AppPalette.accent),
      ),
      title: 'Auto',
      subtitle: kAutoAgentTagline,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// One agent row: its mark, its name and one-line tagline, the reason it can't
/// answer here when there is one, and a tick when it's the one answering.
class _AgentItem extends StatelessWidget {
  const _AgentItem({
    required this.tool,
    required this.subtitle,
    required this.warn,
    required this.selected,
    required this.onTap,
  });

  final AgentTool tool;
  final bool selected;

  /// The tagline, or — when this agent can't answer on the open grid — the reason
  /// why, in the warning tone that [warn] asks for. An installed agent is offered
  /// either way: picking it borrows the chat until a grid that can run it.
  ///
  /// Handed in rather than derived here, because [_menuSize] lays out this exact
  /// string to place the panel and a row that composed its own would be measured
  /// as some other row.
  final String subtitle;
  final bool warn;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return _MenuRow(
      leading: AgentMark(tool: tool, size: _markSize),
      title: tool.name,
      subtitle: subtitle,
      warn: warn,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// The box every row in this menu is drawn in: a mark, a name over one line of
/// explanation, and a tick when it's the one in force.
///
/// One shell rather than one per row kind. The gutters, the row width, the
/// selected wash, the type sizes and the tick are the menu's own look — written
/// twice, a change to the look lands in one row and the other drifts, which on a
/// list whose whole job is to be comparable is exactly the wrong place for it.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.warn = false,
  });

  final Widget leading;
  final String title;
  final String subtitle;

  /// Whether [subtitle] is a reason this row can't be used, rather than a
  /// description of it — said in the warning tone.
  final bool warn;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        splashFactory: NoSplash.splashFactory,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: _rowRadius),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _rowGutter,
          vertical: 3,
        ),
        child: Container(
          width: _menuWidth - _rowGutter * 2,
          padding: const EdgeInsets.fromLTRB(
            _rowInnerPad,
            _rowInnerPadV,
            _rowTrailPad,
            _rowInnerPadV,
          ),
          decoration: BoxDecoration(
            color: selected ? AppSurface.accentWash : Colors.transparent,
            borderRadius: _rowRadius,
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: _markGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // The same styles [_menuSize] lays out — restyling a row
                      // here alone would move the menu off its pill.
                      style: _titleStyle(theme),
                    ),
                    const SizedBox(height: _titleSubtitleGap),
                    Text(
                      subtitle,
                      maxLines: _subtitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: _subtitleStyle(theme, warn: warn),
                    ),
                  ],
                ),
              ),
              // The tick's column is kept whether this row wears one or not: it
              // used to appear only on the selected row, so every other row's
              // text was 24px wider and picking a different agent reflowed the
              // list under the cursor.
              const SizedBox(width: _tickGap),
              SizedBox(
                width: _tickSize,
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: _tickSize,
                        color: AppPalette.accent,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
