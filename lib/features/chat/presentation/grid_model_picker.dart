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
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../logic/grid_model_catalog.dart';

/// Called when the user picks a model: [grid] is the grid that serves it (which
/// becomes the active grid) and [option] is the chosen model / media mode.
typedef GridModelSelected =
    void Function(NetworkCredential grid, PlaygroundModelOption option);

/// The geometry an option row is built from. `_InfoRow` needs to hang its note
/// under the row's *text*, which means knowing where that text starts — it used
/// to carry the hand-added answer (29) and would drift the moment any of these
/// changed.
const _rowGutter = 6.0;
const _rowInnerPad = 9.0;
const _rowIconSlot = 16.0;
const _rowIconGap = 9.0;
final _rowRadius = BorderRadius.circular(AppControl.radius);

/// The panel's fixed width, and what the list can grow to before it scrolls.
const _menuWidth = 340.0;
const _menuMaxListHeight = 300.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: the two drifting apart is what pushes a menu
/// off its button.
const _menuPadding = 5.0;

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

/// What the menu will measure for a catalog of [rows] options.
///
/// Summed from the row's own parts rather than guessed, so
/// [anchoredMenuPosition] lands the panel on the pill instead of near it — and
/// so it follows if the row's padding ever changes. Unlike the other menus in
/// the app this height can't be a constant: the list grows with what the grid
/// serves, and a stale constant is exactly what floats a menu off its anchor.
Size _menuSize(int rows) {
  final list = (_optionRowHeight * rows + _listPadding * 2).clamp(
    0.0,
    _menuMaxListHeight,
  );
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
  });

  final String currentModelId;
  final GridModelSelected onSelect;

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
    // Positioned, not aligned. `MenuStyle.alignment: topRight` reads as "put the
    // menu's top-*left* on the pill's top-right", so a 340px panel grew off to
    // the right and the window-edge clamp parked it against the screen edge —
    // 270px clear of the pill it belongs to. This is the recipe the app's other
    // four menus use.
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize(_rowCount()),
        margin: 8,
        gap: 6,
        alignEnd: true,
        // The pill lives at the bottom of the window, so the menu opens upward;
        // `anchoredMenuPosition` drops back below on its own if it won't fit.
        preferAbove: true,
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
      rows += group.options.length;
    }
    return rows == 0 ? 1 : rows;
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
        visualDensity: VisualDensity.compact,
      ),
      menuChildren: [
        _ModelMenu(
          currentModelId: widget.currentModelId,
          onSelect: widget.onSelect,
          onClose: _menu.close,
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
        return ComposerTrigger(
          label: label,
          tooltip: grid == null || option == null
              ? 'Choose which model answers'
              : '$label\non $grid',
          // The same mark you picked by, so "am I about to chat or to draw?" is
          // answerable at a glance. Null while nothing's picked — the pill then
          // prompts rather than reports.
          leading: option == null
              ? null
              : Icon(
                  modelIcon(option),
                  size: 13,
                  color: modalityTone(option.modality),
                ),
          onTap: () => _toggleMenu(context, controller),
        );
      },
    );
  }

  String _triggerLabel(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return 'Choose model';
    return modelShortLabel(trimmed);
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
      for (final option in group.options) {
        if (modelKey(option.id) == modelKey(trimmed)) return option;
      }
    }
    return PlaygroundModelOption(
      id: trimmed,
      label: trimmed,
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
    required this.onClose,
  });

  final String currentModelId;
  final GridModelSelected onSelect;
  final VoidCallback onClose;

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
    // Both this and the per-grid /models call are autoDispose, so closing the
    // menu tears them down and every open refetches from scratch. That's the
    // churn: grids resolve one by one, each landing pushing the ones below it
    // down, and a ready-but-empty grid now vanishes as it resolves rather than
    // just moving. Hold the skeleton until the whole catalog has settled — a
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
            constraints: const BoxConstraints(maxHeight: _menuMaxListHeight),
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
            onTap: () {
              widget.onSelect(group.grid, option);
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

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
    this.blockedFor,
  });

  final PlaygroundModelOption option;
  final bool selected;
  final VoidCallback onTap;

  /// The agent in force that can't answer with this model — null whenever the
  /// row is pickable. It carries the agent rather than a bare flag so the row
  /// can name who is refusing: "not for Codex" is a fact the user can act on,
  /// "unavailable" is a mystery.
  final AgentTool? blockedFor;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    final blocked = blockedFor;
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
                // composer is on.
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
