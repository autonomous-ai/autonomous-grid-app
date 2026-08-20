import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/composer_trigger.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/modality_mark.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_model_support.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_message.dart';
import '../../network/logic/node_display.dart' show modelKey;
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/grid_model_catalog.dart';
import '../logic/routing_group.dart';
import 'routing_setup_dialog.dart';

/// Called when the user picks a model: [grid] is the grid that serves it (which
/// becomes the active grid) and [option] is the chosen model / media mode.
typedef GridModelSelected =
    void Function(NetworkCredential grid, PlaygroundModelOption option);

/// Called when the user picks one of the orchestrator rows, having said in the
/// same gesture whether the models should be pinned ([fixed]) or re-picked by
/// the grid every message.
typedef _RoutingSelected =
    void Function(
      NetworkCredential grid,
      PlaygroundModelOption option,
      RoutingMode mode, {
      required bool fixed,
    });

/// The geometry an option row is built from. `_InfoRow` needs to hang its note
/// under the row's *text*, which means knowing where that text starts — it used
/// to carry the hand-added answer (29) and would drift the moment any of these
/// changed.
const _rowGutter = 6.0;
const _rowInnerPad = 9.0;
const _rowIconSlot = 16.0;
const _rowIconGap = 9.0;
final _rowRadius = BorderRadius.circular(AppControl.radius);

/// The panel's fixed width.
const _menuWidth = 340.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: the two drifting apart is what pushes a menu
/// off its button.
const _menuPadding = 5.0;

/// The air the panel keeps from the window edge, passed to
/// [anchoredMenuPosition] and used to work out how tall it may draw.
const _menuMargin = 8.0;

/// The tallest this panel may draw: the window, less the margin it keeps at both
/// edges.
///
/// Its own cap rather than [AppControl.menuMaxHeight]'s 240, which fit **six**
/// rows and cut the seventh in half — a grid serving eight models read as a list
/// that had lost two. A model list can genuinely be long, so past this the list
/// still scrolls (and now says so, see the `Scrollbar` in [_ModelMenuState]) — it
/// just uses the window it has first.
double _menuMaxHeight(BuildContext context) =>
    MediaQuery.sizeOf(context).height - _menuMargin * 2;

/// What the list can grow to before it scrolls: the whole panel, less its own
/// padding.
///
/// Derived, not chosen. It used to be a flat 300 while `appMenuStyle` capped the
/// panel at 240 — so a grid serving more than six models built a 310px list
/// inside a 240px panel, which left the menu *twice* scrollable (the panel's own
/// scroll view over this one) and, worse, made the height this picker predicts to
/// place itself 70px taller than what draws: the list opened hanging in the
/// middle of the conversation instead of on the pill. Same trap, same rule — the
/// list's cap and the panel's must be the same number.
double _maxListHeight(BuildContext context) =>
    _menuMaxHeight(context) - _menuPadding * 2;

/// What one option row measures, measured with `getRect` rather than derived:
/// text at 13/1.2 rounds up to a 16px line box inside `vertical: 8`, and the
/// gutter adds 1px above and below. Reading the row's padding off the source and
/// adding it up gives 33.6 and drifts the panel — this is the number the row
/// actually occupies.
const _optionRowHeight = 34.0;

/// The list's own padding, above the first row and below the last.
const _listPadding = 6.0;

/// How many rows [_LoadingRows] stands in with. Shared so the placement made
/// while the catalog is in flight matches the panel that actually draws.
const _loadingRowCount = 3;

/// What [_EmptyNote] occupies: 22 above and 24 below a single 12.5/1.3 line.
///
/// Its own number because it is nothing like an option row. Counted as one
/// `_optionRowHeight` the estimate came out ~29px short, and a panel placed
/// 29px low grows down over the pill it hangs off — which is what a grid
/// serving no models looked like: the "isn't serving a model" panel sitting on
/// top of the composer instead of above it.
const _emptyNoteHeight = 63.0;

/// What the menu will measure for a catalog of [rows] options.
///
/// Summed from the row's own parts rather than guessed, so
/// [anchoredMenuPosition] lands the panel on the pill instead of near it — and
/// so it follows if the row's padding ever changes. Unlike the other menus in
/// the app this height can't be a constant: the list grows with what the grid
/// serves, and a stale constant is exactly what floats a menu off its anchor.
///
/// Capped by [_maxListHeight] at exactly what the panel can draw, so a grid
/// serving twenty models places the same as one serving three.
Size _menuSize(BuildContext context, int rows) {
  // `rows == 0` is the empty state, which draws one [_EmptyNote] rather than no
  // rows at all — see [_emptyNoteHeight].
  final content = rows == 0 ? _emptyNoteHeight : _optionRowHeight * rows;
  final list = (content + _listPadding * 2).clamp(0.0, _maxListHeight(context));
  return Size(_menuWidth, _menuPadding * 2 + list);
}

/// The composer's model control: a compact pill that opens the list of models
/// the grid you're on is serving.
///
/// It carried a search field and a grid-name heading back when it listed every
/// grid you belong to. It lists one grid now — the active one — so the heading
/// repeated the pill right under it, and the search stood between the user and a
/// handful of rows they could already see.
class GridModelPicker extends ConsumerStatefulWidget {
  const GridModelPicker({
    super.key,
    required this.currentModelId,
    required this.onSelect,
    this.visionBlocked = false,
    this.selectedModel,
  });

  final String currentModelId;
  final GridModelSelected onSelect;

  /// True when an image is attached but the selected model can't read images —
  /// highlights the pill and prompts for a vision-capable model. Only ever for a
  /// text model: media modes take images via their own endpoints.
  final bool visionBlocked;

  /// The picked model, or null while nothing is / the list hasn't landed.
  final PlaygroundModelOption? selectedModel;

  @override
  ConsumerState<GridModelPicker> createState() => _GridModelPickerState();
}

class _GridModelPickerState extends ConsumerState<GridModelPicker> {
  final _menu = MenuController();

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    // What a grid serves changes while the app is open and nothing re-reads it
    // on its own, so the list you open is the one the app saw at launch. Asked
    // for here, before the panel opens, so the answer lands into an open menu —
    // and without blanking it, see [refreshGridModelCatalog].
    refreshGridModelCatalog(ref);
    // Positioned, not aligned. `MenuStyle.alignment: topRight` reads as "put the
    // menu's top-*left* on the pill's top-right", so a 340px panel grew off to
    // the right and the window-edge clamp parked it against the screen edge —
    // 270px clear of the pill it belongs to. This is the recipe the app's other
    // four menus use.
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize(context, _rowCount()),
        margin: _menuMargin,
        gap: AppControl.menuGap,
        alignEnd: true,
        // The pill lives at the bottom of the window, so the menu opens upward;
        // `anchoredMenuPosition` drops back below on its own if it won't fit.
        preferAbove: true,
        // The same cap the panel and its list are drawn with — three numbers that
        // must agree, or the panel is placed for a height it never takes.
        maxHeight: _menuMaxHeight(context),
      ),
    );
  }

  /// How many rows the menu is about to show — what [_menuSize] needs to place
  /// the panel. Counts what [_ModelMenu] builds: one row per option, one note
  /// per grid that can't list any, and the empty note when there's nothing.
  int _rowCount() {
    final catalog = ref.read(gridModelCatalogProvider);
    if (catalog.any((g) => g.status == GridModelStatus.loading)) {
      return _loadingRowCount;
    }
    var rows = 0;
    for (final group in catalog) {
      if (group.options.isEmpty) {
        if (group.status != GridModelStatus.ready) rows++;
        continue;
      }
      rows += group.options.length + routingModeOptions(group.options).length;
    }
    // Zero is meaningful, not a floor to clamp away: [_menuSize] reads it as the
    // empty state, whose one note is taller than an option row.
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    // The menu's surface reads tokens; follow theme flips.
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      // The shared surface, not a hand-rolled one. This menu used to carry its
      // own: `AppPalette.cardBg` is picked to be read *on the page*, so as a
      // floating panel over the composer it had no edge of its own, and its
      // 8/radius-14 lift disagreed with every other menu in the app.
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuPadding),
        ),
        // The shared 240 cap lifted — see [_menuMaxHeight]. The list inside is
        // held to the same number less this padding, so neither clips the other.
        maximumSize: WidgetStatePropertyAll(
          Size.fromHeight(_menuMaxHeight(context)),
        ),
        visualDensity: VisualDensity.compact,
      ),
      menuChildren: [
        _ModelMenu(
          currentModelId: widget.currentModelId,
          onSelect: _select,
          onSelectRouting: _selectRouting,
          onClose: _menu.close,
          visionBlocked: widget.visionBlocked,
        ),
      ],
      builder: (context, controller, _) {
        final option = _triggerOption(
          ref.watch(gridModelCatalogProvider),
          widget.currentModelId,
        );
        // Which grid, not just which model: two grids can serve the same id (and
        // do — the same qwen sits on several), so the name alone left "whose
        // machine is answering, and on whose bill" unanswerable. It rides the
        // tooltip, not the pill's face — a question asked once a session.
        final grid = ref.watch(selectedNetworkProvider)?.name;
        final label = _triggerLabel(widget.currentModelId);
        // An attached image the model can't read: the pill warns instead of
        // reporting the choice, so "why won't Send?" is answered by the control
        // that needs to change.
        final blocked = widget.visionBlocked;
        return ComposerTrigger(
          label: label,
          tooltip: blocked
              ? "You attached an image — pick a model that can read it to send"
              : grid == null || option == null
              ? 'Choose which model answers'
              : '$label\non $grid',
          // The same mark you picked by, so "am I about to chat or to draw?" is
          // answerable at a glance. Null while nothing's picked — the pill then
          // prompts rather than reports. While vision-blocked, the mark (and the
          // warning frame) are drawn in the error tone so the eye lands on it.
          leading: option == null
              ? null
              : Icon(
                  modelIcon(option),
                  size: 13,
                  color: blocked
                      ? Theme.of(context).colorScheme.error
                      : modalityTone(option.modality),
                ),
          // The composer trigger normally has no rim; a vision-blocked model gets
          // one in the error tone so it reads as "fix me", not as a quiet choice.
          borderColor: blocked ? Theme.of(context).colorScheme.error : null,
          onTap: () => _toggleMenu(context, controller),
        );
      },
    );
  }

  /// An ordinary model pick, on its way to the composer.
  ///
  /// Moving to a plain model hands the chat back to the grid's ordinary pick:
  /// a group left behind would go on pinning models the composer no longer
  /// names.
  void _select(NetworkCredential grid, PlaygroundModelOption option) {
    ref.read(chatSessionsProvider.notifier).clearRoutingGroup();
    widget.onSelect(grid, option);
  }

  /// An orchestrator row, with the Fixed/Dynamic answer the row's own little
  /// menu already collected (see [_ModeChoiceRow]).
  ///
  /// **Dynamic costs nothing and asks nothing.** It has no model list to hold,
  /// so there is no suggestion to fetch and no dialog to show (design spec §4)
  /// — the group is written on the spot and the composer moves. This is why
  /// the choice is made *before* the setup dialog rather than inside it: that
  /// dialog probes the grid with a real, billed chat completion the moment it
  /// opens, and a user who wanted Dynamic would have paid for an answer they
  /// were always going to decline.
  void _selectRouting(
    NetworkCredential grid,
    PlaygroundModelOption option,
    RoutingMode mode, {
    required bool fixed,
  }) {
    if (!fixed) {
      ref
          .read(chatSessionsProvider.notifier)
          .setRoutingGroup(RoutingGroup(mode: mode, isFixed: false));
      widget.onSelect(grid, option);
      return;
    }
    unawaited(_setUpFixedRouting(grid, option, mode));
  }

  /// Ask which models [mode] should pin in this chat, then pin them.
  ///
  /// Once per chat per mode: coming back to a mode this chat is already pinned
  /// to keeps the models the user confirmed, rather than spending another
  /// request on a suggestion and asking them the same question again. A chat
  /// on this mode *dynamically* is not already set up — that is the pick
  /// changing, and it is what the dialog is for.
  ///
  /// Run from the pill rather than from inside the menu because the menu is
  /// torn down the moment a row is tapped — the dialog has to hang off
  /// something that is still on screen when it opens.
  Future<void> _setUpFixedRouting(
    NetworkCredential grid,
    PlaygroundModelOption option,
    RoutingMode mode,
  ) async {
    final chats = ref.read(chatSessionsProvider.notifier);
    final chat = ref.read(chatSessionsProvider).active;
    final pinned = chat?.routingGroup;
    if (pinned != null && pinned.mode == mode && pinned.isFixed) {
      widget.onSelect(grid, option);
      return;
    }
    final group = await showRoutingSetupDialog(
      context,
      mode: mode,
      // What the suggestion is asked to read: an empty list for a chat with
      // nothing said in it yet, which is the common case for this dialog.
      conversation: chat?.messages ?? const [],
    );
    // Cancelled — the composer keeps whatever it was on. Falling through to
    // the plain mode string would leave the chat routed a way the user backed
    // out of, with the pill saying so.
    if (!mounted || group == null) return;
    chats.setRoutingGroup(group);
    widget.onSelect(grid, option);
  }

  String _triggerLabel(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return 'Choose model';
    // The orchestrator rows are named, not derived: `modelShortLabel` would
    // read `auto/brute_force` as a maker-prefixed id and put "brute_force" on
    // the pill.
    return routingModeForModelId(trimmed)?.displayName ??
        modelShortLabel(trimmed);
  }

  /// The selected model as the menu knows it, so the pill wears the same mark
  /// the row did — including whether it runs on the grid or in a cloud. The pill
  /// used to derive a bare modality from the id, which is all an id can tell
  /// you, so every text model came out with the plain text glyph while the menu
  /// two centimetres above it said otherwise.
  ///
  /// Falls back to what the id alone says when the catalog hasn't landed (or the
  /// user typed an id by hand): the media modes carry fixed labels, and hosting
  /// stays unclaimed. Null while nothing is picked — "Choose model" is a prompt,
  /// not a selection.
  PlaygroundModelOption? _triggerOption(
    List<GridModelGroup> groups,
    String id,
  ) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    for (final group in groups) {
      for (final option in [
        ...group.options,
        ...routingModeOptions(group.options),
      ]) {
        if (modelKey(option.id) == modelKey(trimmed)) return option;
      }
    }
    return PlaygroundModelOption(
      id: trimmed,
      label: modelDisplayLabel(trimmed),
      modality: switch (trimmed) {
        kImageModeLabel => PlaygroundModality.image,
        kVideoModeLabel => PlaygroundModality.video,
        _ => PlaygroundModality.text,
      },
    );
  }
}

/// The dropdown body: the scrollable list of what this grid serves. Stateful for
/// its own scroll controller; the models come from [gridModelCatalogProvider].
class _ModelMenu extends ConsumerStatefulWidget {
  const _ModelMenu({
    required this.currentModelId,
    required this.onSelect,
    required this.onSelectRouting,
    required this.onClose,
    this.visionBlocked = false,
  });

  final String currentModelId;
  final GridModelSelected onSelect;

  /// The orchestrator rows have a second question of their own — see
  /// [_ModeChoiceRow] — so they report through their own callback rather than
  /// squeezing the answer into [onSelect]'s option.
  final _RoutingSelected onSelectRouting;
  final VoidCallback onClose;

  /// Set while an image is attached but the picked model can't read it — rows
  /// then mark every model by whether it can carry the turn.
  final bool visionBlocked;

  @override
  ConsumerState<_ModelMenu> createState() => _ModelMenuState();
}

class _ModelMenuState extends ConsumerState<_ModelMenu> {
  // Its own controller, not the ambient primary one: MenuAnchor wraps its
  // children in a scroll view of its own, so an inherited PrimaryScrollController
  // ends up with two ScrollPositions and the Scrollbar asserts.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Menu content — detached from the anchor's rebuilds; watch theme itself.
    AppTheme.watch(context);
    final catalog = ref.watch(gridModelCatalogProvider);
    final currentGridId = ref.watch(selectedNetworkProvider)?.networkId;
    // Who answers decides what can be picked: a seat model only its own vendor's
    // CLI can drive is shown, but dead, rather than hidden — a model that
    // vanishes when you change assistant reads as the grid losing it.
    final agent = ref.watch(chatModelAgentProvider);
    // The first load only. The pill above watches the same catalog, so it never
    // auto-disposes, and the re-read every open asks for keeps the rows it
    // already had — a refresh reads as ready throughout and lands as a swap.
    // What's left to hold the skeleton for is a grid with nothing cached yet: a
    // list that assembles itself in front of you is the thing to avoid, and
    // there's nothing to pick from mid-flight anyway.
    final settling = catalog.any((g) => g.status == GridModelStatus.loading);

    // A fixed width lets the menu's IntrinsicWidth size without measuring the
    // list. A SingleChildScrollView (unlike a lazy ListView) can be
    // intrinsic-measured, so it's safe inside the menu.
    return SizedBox(
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _maxListHeight(context)),
            // A list long enough to be cut has to say so. The menu panel draws a
            // scrollbar for *its* scroll view, but this list is a second one
            // inside it — and it is the one that scrolls, since the panel is now
            // capped at exactly what this list plus the panel padding takes. So
            // without this the models past the fold scrolled silently.
            // Safe with the dedicated controller below: the assert this used to
            // hit came from inheriting the ambient primary one.
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                primary: false,
                padding: const EdgeInsets.symmetric(vertical: _listPadding),
                child: settling
                    ? const _LoadingRows()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _rows(catalog, currentGridId, agent),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(
    List<GridModelGroup> catalog,
    String? currentGridId,
    AgentTool? agent,
  ) {
    final rows = <Widget>[];
    for (final group in catalog) {
      // A grid with nothing to offer says why — loading, or offline. A *ready*
      // one serving nothing has no row of its own to explain: the empty note
      // below covers it, and a heading-less list has nothing to hang it under.
      if (group.options.isEmpty) {
        if (group.status != GridModelStatus.ready) {
          rows.add(_InfoRow(status: group.status));
        }
        continue;
      }
      for (final option in group.options) {
        rows.add(
          _OptionRow(
            option: option,
            selected:
                group.grid.networkId == currentGridId &&
                option.id == widget.currentModelId,
            // The agent that would answer with it, when it can't — the row then
            // says so instead of taking a tap that ends at the relay's refusal.
            blockedFor: agent != null && !agentSupportsModel(agent, option.id)
                ? agent
                : null,
            // While an image is attached that the picked model can't read, every
            // text-model row says whether it can carry the turn, so switching is
            // one readable tap instead of a hunt.
            visionContext: widget.visionBlocked,
            onTap: () {
              widget.onSelect(group.grid, option);
              widget.onClose();
            },
          ),
        );
      }
      // The grid's own models first, then the two ways of putting several of
      // them on one question. They go last because they are the rarer choice
      // and because they read as a footnote to the list they draw from — see
      // [routingModeOptions].
      for (final option in routingModeOptions(group.options)) {
        final mode = routingModeForModelId(option.id);
        // Unreachable — every row [routingModeOptions] builds is named after a
        // mode — but this is a lookup, not an invariant worth a `!` (§3).
        if (mode == null) continue;
        rows.add(
          _ModeChoiceRow(
            option: option,
            selected:
                group.grid.networkId == currentGridId &&
                option.id == widget.currentModelId,
            onPick: (fixed) {
              widget.onSelectRouting(group.grid, option, mode, fixed: fixed);
              widget.onClose();
            },
          ),
        );
      }
    }
    // Nothing to pick — the one case where the empty picker has to explain
    // itself rather than open onto a blank panel.
    if (rows.isEmpty) {
      rows.add(
        const _EmptyNote(message: "This grid isn't serving a model right now."),
      );
    }
    return rows;
  }
}

/// An orchestrator row — it asks *how* before it asks the grid anything.
///
/// Fixed and Dynamic are two different promises about the same mode: one pins a
/// set of models for the whole chat, the other lets the grid re-pick every
/// message. Only Fixed needs the setup dialog behind it, and that dialog spends
/// a real, billed chat completion on a suggestion the moment it opens. So the
/// choice is made here, in a two-item menu off the row, rather than inside the
/// dialog — a user who wanted Dynamic never pays for an answer they were always
/// going to decline (design spec §4: Dynamic has no suggestion step).
///
/// Draws as an ordinary [_OptionRow] so the list stays one list; the only
/// difference is that its tap opens a menu instead of closing the picker. A
/// [MenuAnchor] nested inside the picker's own menu children — the shape
/// `SubmenuButton` is itself built from, so the outer panel stays open behind
/// it rather than treating the submenu's tap as a tap outside.
class _ModeChoiceRow extends StatelessWidget {
  const _ModeChoiceRow({
    required this.option,
    required this.selected,
    required this.onPick,
  });

  final PlaygroundModelOption option;
  final bool selected;

  /// True for Fixed, false for Dynamic.
  final ValueChanged<bool> onPick;

  @override
  Widget build(BuildContext context) {
    // menuChildren draw in a detached overlay, so a parent's rebuild doesn't
    // reach them — this has to watch theme itself, as the app's other nested
    // menus do.
    AppTheme.watch(context);
    return MenuAnchor(
      style: appMenuStyle(),
      menuChildren: [
        for (final fixed in const [true, false])
          _ModeItem(
            label: fixed ? 'Fixed' : 'Dynamic',
            note: routingHoldNote(isFixed: fixed),
            onPressed: () => onPick(fixed),
          ),
      ],
      builder: (context, controller, _) => _OptionRow(
        option: option,
        selected: selected,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// One half of the Fixed/Dynamic choice: the word, and the one line saying what
/// it actually promises — which is the whole difference between them, and not
/// something either word carries on its own.
class _ModeItem extends StatelessWidget {
  const _ModeItem({
    required this.label,
    required this.note,
    required this.onPressed,
  });

  final String label;
  final String note;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return MenuItemButton(
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              note,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.2,
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
    this.blockedFor,
    this.visionContext = false,
  });

  final PlaygroundModelOption option;
  final bool selected;
  final VoidCallback onTap;

  /// The agent in force that can't answer with this model — null whenever the
  /// row is pickable. It carries the agent rather than a bare flag so the row
  /// can name who is refusing: "not for Codex" is a fact the user can act on,
  /// "unavailable" is a mystery.
  final AgentTool? blockedFor;

  /// True while an image is attached and the picked model can't read it. Every
  /// text-model row then says whether it can carry the turn, so the switch
  /// that unlocks Send is one readable tap.
  final bool visionContext;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    final blocked = blockedFor;
    // This row is a text model that can't read the attached image — the very
    // thing blocking Send when it is the picked row.
    final visionBlocked =
        visionContext &&
        option.modality == PlaygroundModality.text &&
        !option.vision;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _rowGutter, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: _rowRadius,
        child: InkWell(
          // Dead, not hidden: a null tap leaves the row visible and legible so
          // the list still says what the grid serves.
          onTap: blocked == null ? onTap : null,
          borderRadius: _rowRadius,
          hoverColor: AppSurface.hoverFill,
          // macOS clicks land instantly; the global InkRipple would spread a
          // circle across the row. Hover is the affordance here.
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              // Same wash + ticked-disc language as the approval menu, so "the
              // one in force" looks the same wherever the composer says it.
              color: selected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: _rowRadius,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: _rowInnerPad,
              vertical: 8,
            ),
            child: Row(
              children: [
                // Every row gets a glyph, because the rows are no longer all the
                // same kind of thing: a grid mixes chat models with the media
                // *modes* its nodes offer, and those do different jobs from the
                // same list. Leaving text blank made the column say only half of
                // that — a gap where a chat model's mark should be reads as
                // missing data, not as "this is the ordinary one".
                SizedBox(
                  width: _rowIconSlot,
                  child: Icon(
                    modelIcon(option),
                    size: AppControl.iconSize,
                    color: blocked != null
                        ? AppPalette.textFaint
                        : selected
                        ? AppPalette.accentMuted
                        : modalityTone(option.modality),
                  ),
                ),
                const SizedBox(width: _rowIconGap),
                Expanded(
                  child: Text(
                    option.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: selected ? AppFont.medium : FontWeight.w400,
                      color: blocked != null
                          ? AppPalette.textFaint
                          : AppPalette.textPrimary,
                    ),
                  ),
                ),
                // Who is refusing, where the tick would sit — the two never
                // collide, since a model the agent can't use is not one the
                // composer is on. While the picked model is vision-blocked, rows
                // instead say whether a text model can read the image, so the
                // one tap that unlocks Send is marked.
                if (blocked != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    agentModelBlockedLabel(blocked),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: AppPalette.textFaint,
                    ),
                  ),
                ] else if (visionBlocked) ...[
                  const SizedBox(width: 8),
                  Text(
                    "Can't read images",
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ] else if (selected) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppPalette.accentMuted,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                  ),
                  // A candidate worth switching to, or one that would not help —
                  // marked once an image is attached and the current pick can't
                  // read it.
                ] else if (visionContext &&
                    option.modality == PlaygroundModality.text) ...[
                  const SizedBox(width: 8),
                  Text(
                    option.vision ? 'Reads images' : 'No vision',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: option.vision
                          ? AppPalette.textSecondary
                          : AppPalette.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (blocked == null) return row;
    // The whole sentence on hover, since the row itself has room for three
    // words. Only the blocked row gets it: a tooltip on the pickable ones would
    // be a nag with nothing to say.
    return Tooltip(message: agentModelBlockedReason(blocked), child: row);
  }
}

/// The menu's shape while the grid is still answering.
///
/// Mirrors what lands — a short column of model rows — so the list holds one
/// height from open to settled and nothing moves out from under the pointer.
class _LoadingRows extends StatelessWidget {
  const _LoadingRows();

  @override
  Widget build(BuildContext context) {
    const rows = _loadingRowCount;
    // The glyph is the tallest thing in the row, so the padding that makes a
    // skeleton row measure a model row's height is whatever's left over. Spelled
    // as the difference rather than hand-added: the placement in _menuSize sizes
    // the panel off _optionRowHeight, and a skeleton row that measured something
    // else would move the list under the pointer as the catalog lands.
    const pad = (_optionRowHeight - _rowIconSlot) / 2;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows; r++)
          Opacity(
            // Fade down the column so the block reads as "more below" rather
            // than a slab that stops dead — the same trick SkeletonList uses.
            opacity: 1 - (r / rows) * 0.5,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                _rowGutter + _rowInnerPad,
                pad,
                _rowInnerPad,
                pad,
              ),
              child: Row(
                children: [
                  // Every row carries a glyph, so the wait shows one too — an
                  // empty slot here would collapse into the label the moment the
                  // real icons landed.
                  const Skeleton(
                    width: _rowIconSlot,
                    height: _rowIconSlot,
                    radius: 4,
                  ),
                  const SizedBox(width: _rowIconGap),
                  Skeleton(width: r.isEven ? 150 : 116, height: 11, radius: 3),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The whole list is empty — no grid has anything to offer, or the search found
/// nothing. Centred and given room, because it *is* the menu at that point
/// rather than a note tucked under one grid's header.
class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.3,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}

/// A muted line for a grid that can't list its models yet: still loading, or
/// unreachable. A ready grid serving nothing falls to the empty note instead, so
/// [GridModelStatus.ready] never reaches here.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.status});

  final GridModelStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    final message = switch (status) {
      GridModelStatus.loading => 'Loading models…',
      GridModelStatus.offline => 'Grid is offline',
      // Unreachable via the picker's filter, but this is a public-ish widget in
      // the file — keep it honest rather than throwing.
      GridModelStatus.ready => 'No models available',
    };
    return Padding(
      // Indented to the option rows' text, not their icon: this is the absence
      // of rows, so it reads as a note rather than lining up as one more thing
      // you could pick. Spelled as the sum of the row's own parts so it follows
      // them; it used to be the hand-added answer, 29.
      padding: const EdgeInsets.fromLTRB(
        _rowGutter + _rowInnerPad + _rowIconSlot + _rowIconGap,
        2,
        15,
        8,
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          fontStyle: FontStyle.italic,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}
