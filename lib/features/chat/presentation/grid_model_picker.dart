import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/modality_mark.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/logic/session_controller.dart';
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
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    // The menu's surface reads tokens; follow theme flips.
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      // Hang the menu off the pill's top-right and let MenuAnchor measure it.
      // A declared height can't be right here: the list grows with the number of
      // grids and shrinks as you type in the search, so any constant is stale the
      // moment the catalog loads — too short clipped the last row, too tall
      // floated the menu off the pill.
      alignmentOffset: const Offset(0, -8),
      style: MenuStyle(
        alignment: Alignment.topRight,
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStatePropertyAll(AppPalette.cardBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        _ModelMenu(
          currentModelId: widget.currentModelId,
          onSelect: widget.onSelect,
          onClose: _menu.close,
        ),
      ],
      builder: (context, controller, _) => _TriggerButton(
        label: _triggerLabel(widget.currentModelId),
        // Which grid, not just which model: two grids can serve the same id (and
        // do — the same qwen sits on several), so the name alone left "whose
        // machine is answering, and on whose bill" unanswerable without
        // reopening the menu. The menu has always keyed its tick on grid+id;
        // the pill was reporting half of what the menu knew.
        grid: ref.watch(selectedNetworkProvider)?.name,
        option: _triggerOption(
          ref.watch(gridModelCatalogProvider),
          widget.currentModelId,
        ),
        onTap: () => _toggleMenu(context, controller),
      ),
    );
  }

  String _triggerLabel(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return 'Choose model';
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
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

/// The pill that sits in the composer: the model that will answer, and a caret.
/// Quiet by design — it's a property of the message, not a call to action.
class _TriggerButton extends StatelessWidget {
  const _TriggerButton({
    required this.label,
    required this.grid,
    required this.option,
    required this.onTap,
  });

  final String label;

  /// The grid serving [label], or null before one is resolved.
  final String? grid;

  /// The model that will answer, as the menu knows it — null while nothing is
  /// picked, when the pill is prompting rather than reporting.
  final PlaygroundModelOption? option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppPalette/AppGlass tokens — follow theme flips
    return Tooltip(
      // Which grid lives here, not on the pill's face. There is room for it —
      // the label uses 86 of the pill's 140px — but the pill is chrome that sits
      // under the text box all day, and the grid only matters at the moment you
      // wonder about it. The menu's tick keys on grid+id, so the answer is one
      // hover or one click away; spending the composer's quietest strip on it
      // would be paying rent for a question that's asked once a session.
      message: grid == null || option == null
          ? 'Choose which model answers'
          : '$label\non $grid',
      child: OutlinedButton(
        onPressed: onTap,
        // Chrome, not a call to action: it reports what will answer, so it stays
        // unfilled and unrimmed and lets the composer's own surface carry it.
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.textPrimary,
          backgroundColor: Colors.transparent,
          side: BorderSide.none,
          // Matches the approval pill beside it: same height, same radius. The
          // two used to disagree on both — stadium at a forced 30 next to a
          // circular(999) at 28.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
          padding: AppControl.paddingSmall,
          // minimumSize alone is only a floor — the button's own vertical
          // padding still pushed this to 48, which is why the call site used to
          // wrap it in a SizedBox(height: 30) to force it back down. Pin both
          // ends and the pill sizes itself.
          minimumSize: const Size.fromHeight(AppControl.heightSmall),
          maximumSize: const Size.fromHeight(AppControl.heightSmall),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          splashFactory: NoSplash.splashFactory,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The same mark you picked by, kept next to the name — so "am I
            // about to chat or to draw?" is answerable at a glance, without
            // reopening the menu. A model id like "ornith-1.0-35b" never said.
            if (option != null) ...[
              Icon(
                modelIcon(option!),
                size: 13,
                color: modalityTone(option!.modality),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 1),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: AppPalette.textFaint,
            ),
          ],
        ),
      ),
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
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              controller: _scroll,
              primary: false,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: settling
                  ? const _LoadingRows()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _rows(catalog, currentGridId),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(List<GridModelGroup> catalog, String? currentGridId) {
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
  });

  final PlaygroundModelOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _rowGutter, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: _rowRadius,
        child: InkWell(
          onTap: onTap,
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
                    color: selected
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
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
                if (selected) ...[
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
    const rows = 3;
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
              // Matches _OptionRow's own gutter + inner pad + row height, so a
              // skeleton row occupies exactly what a model row will.
              padding: const EdgeInsets.fromLTRB(
                _rowGutter + _rowInnerPad,
                5,
                _rowInnerPad,
                5,
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
