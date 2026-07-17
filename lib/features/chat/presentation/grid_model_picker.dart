import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
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

/// The hairline above a group heading. Named so a test can tell it apart from
/// the identical rule under the search field — counting bare 1px containers
/// would pass for the wrong reason.
const groupRuleKey = ValueKey('grid-model-picker.group-rule');

/// The composer's model control. A compact pill opens a searchable menu that
/// lists every grid's models grouped under the grid's name — picking one switches
/// the active grid and the model together, so choosing "who answers" is one
/// decision rather than two dropdowns.
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
        modality: _triggerModality(widget.currentModelId),
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

  /// The two media modes carry fixed labels rather than `maker/name` ids (see
  /// [kImageModeLabel]), so what's selected is readable straight from the id —
  /// no need to thread the modality down from the catalog just to mark the pill.
  /// Null while nothing is picked: "Choose model" is a prompt, not a mode.
  PlaygroundModality? _triggerModality(String id) => switch (id.trim()) {
    '' => null,
    kImageModeLabel => PlaygroundModality.image,
    kVideoModeLabel => PlaygroundModality.video,
    _ => PlaygroundModality.text,
  };
}

/// The pill that sits in the composer: the model that will answer, and a caret.
/// Quiet by design — it's a property of the message, not a call to action.
class _TriggerButton extends StatelessWidget {
  const _TriggerButton({
    required this.label,
    required this.grid,
    required this.modality,
    required this.onTap,
  });

  final String label;

  /// The grid serving [label], or null before one is resolved.
  final String? grid;

  /// Null while nothing is picked — the pill is prompting, not reporting.
  final PlaygroundModality? modality;
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
      message: grid == null || modality == null
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
            if (modality != null) ...[
              Icon(
                modalityIcon(modality!),
                size: 13,
                color: modalityTone(modality!),
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

/// The dropdown body: a search field over a scrollable list of models grouped by
/// grid. Kept stateful for the live search query; the model catalog itself comes
/// from [gridModelCatalogProvider].
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
  final _search = TextEditingController();
  // Its own controller, not the ambient primary one: MenuAnchor wraps its
  // children in a scroll view of its own, so an inherited PrimaryScrollController
  // ends up with two ScrollPositions and the Scrollbar asserts.
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() => _query = _search.text.trim());

  bool _matches(PlaygroundModelOption option) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return option.label.toLowerCase().contains(q) ||
        option.id.toLowerCase().contains(q);
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
    // list. The pinned search sits above a bounded, scrollable body — a
    // SingleChildScrollView (unlike a lazy ListView) can be intrinsic-measured,
    // so it's safe inside the menu.
    return SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchField(controller: _search, onChanged: _onQueryChanged),
          // A hairline, not Material's default Divider — that one is a full-width
          // rule in the theme's outline colour and cut the menu visibly in two.
          Container(height: 1, color: AppGlass.hair),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              controller: _scroll,
              primary: false,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: settling
                  ? _LoadingRows(grids: catalog.length)
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
      final matches = group.options.where(_matches).toList();
      // With a query typed, hide grids that match nothing to keep the list tight.
      if (_query.isNotEmpty && matches.isEmpty) continue;
      // A ready grid serving nothing is just noise in a list you opened to pick
      // a model from — four headers reading "No models available" pushed the
      // grids that *do* serve something below the fold. Loading and offline
      // still show: those say "not yet" and "something's wrong", which are
      // answers to "why isn't my grid here?"; silently dropping them would make
      // a grid the user knows they have look like it had been forgotten.
      if (_query.isEmpty &&
          matches.isEmpty &&
          group.status == GridModelStatus.ready) {
        continue;
      }
      // "First" means the first header actually rendered, not the first grid in
      // the catalog — the one above it may well have been filtered out, and a
      // rule hanging above the top row would divide it from nothing.
      rows.add(_GroupHeader(name: group.grid.name, first: rows.isEmpty));
      if (matches.isEmpty) {
        rows.add(_InfoRow(status: group.status));
        continue;
      }
      for (final option in matches) {
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
    // Everything got filtered out. With a query that means "no match"; without
    // one it means every grid you have is serving nothing — a different fact,
    // and the only case where the empty picker needs to explain itself.
    if (rows.isEmpty) {
      rows.add(
        _EmptyNote(
          message: _query.isEmpty
              ? 'No grid is serving a model right now.'
              : 'No model matches “$_query”.',
        ),
      );
    }
    return rows;
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: TextField(
        controller: controller,
        autofocus: true,
        onChanged: (_) => onChanged(),
        style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          hintText: 'Search models',
          hintStyle: TextStyle(fontSize: 13, color: AppPalette.textFaint),
          prefixIcon: Icon(Icons.search, size: 16, color: AppPalette.textFaint),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          // A recessed well rather than an outlined box: autofocus meant the
          // field opened already focused, so an OutlineInputBorder lit its full
          // 2px accent rim every single time the menu opened — the loudest thing
          // on screen, reading as an error state rather than as a search box.
          filled: true,
          fillColor: AppSurface.recess,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide(color: AppPalette.accent, width: 1),
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.name, required this.first});

  final String name;

  /// The first group needs no rule above it — there's nothing to divide it from.
  final bool first;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A hairline is what actually says "a new grid starts here". The header
        // used to lean on its own text to do that, but a heading can only be
        // read — a rule is *seen*, before you read anything, and it's what makes
        // the list a set of blocks instead of one long column.
        if (!first) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              key: groupRuleKey,
              height: 1,
              color: AppGlass.hair,
            ),
          ),
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(14, first ? 6 : 10, 14, 5),
          child: Row(
            children: [
              // The bolt is the grid's mark — it earns the brand gold here,
              // where it labels a grid, rather than the same grey as the name.
              Icon(Icons.bolt, size: 13, color: AppPalette.brandBolt),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  name.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    // textSecondary, not textFaint: this labels the rows under
                    // it, and the faintest ink in the system sat *below* the
                    // textPrimary of the very rows it was meant to introduce —
                    // the heading was quieter than the thing it headed.
                    color: AppPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
                    modalityIcon(option.modality),
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
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

/// What a row *does*, not what it is: a chat model answers in words, the image
/// mode draws, the video mode takes a picture and moves it. The media entries
/// aren't models at all — they're modes the grid's nodes offer — so the glyph is
/// what tells them apart from the model ids beside them.
///
/// Shared by the menu rows and the composer's pill, so the mark you pick by is
/// the mark you're left looking at.
IconData modalityIcon(PlaygroundModality modality) => switch (modality) {
  // A speech bubble, not a robot: every row here is served by a model, so "this
  // is an AI" was the one thing the mark didn't need to say. What sets this row
  // apart is that it answers you in text.
  PlaygroundModality.text => Icons.chat_bubble_outline_rounded,
  PlaygroundModality.image => Icons.auto_awesome_outlined,
  // Not a film reel — the mode's whole point is that it starts from an image you
  // attach. The play-on-a-frame says "your picture, moving".
  PlaygroundModality.video => Icons.slideshow_outlined,
};

/// Chat is the ordinary case and stays in the quiet ink; the media modes are the
/// exceptions and carry a tint, so the eye finds them without the row having to
/// shout. Same reasoning as the approval menu's per-mode hues — colour marks
/// what differs, not everything.
Color modalityTone(PlaygroundModality modality) => switch (modality) {
  PlaygroundModality.text => AppPalette.textFaint,
  PlaygroundModality.image => AppPalette.teal,
  PlaygroundModality.video => AppPalette.brandBolt,
};

/// The menu's shape while the grids are still answering.
///
/// Mirrors what lands: a group heading over a couple of model rows, per grid.
/// The point isn't decoration — it's that the list holds one height from open to
/// settled, so nothing under the pointer moves out from under it.
class _LoadingRows extends StatelessWidget {
  const _LoadingRows({required this.grids});

  /// How many grids are in the catalog. Clamped: one grid still deserves a
  /// list-shaped wait, and past three the menu scrolls anyway.
  final int grids;

  @override
  Widget build(BuildContext context) {
    final groups = grids.clamp(1, 3);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < groups; i++)
          Opacity(
            // Fade down the column so the block reads as "more below" rather
            // than a slab that stops dead — the same trick SkeletonList uses.
            opacity: 1 - (i / groups) * 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The rule between groups is part of the shape now, so the wait
                // carries it too — otherwise it appears out of nowhere on the
                // frame the names land and shoves every row below it down.
                if (i > 0) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Container(height: 1, color: AppGlass.hair),
                  ),
                ],
                // Stands in for _GroupHeader: same box, same 13px bolt slot, so
                // the heading doesn't hop when the name arrives.
                Padding(
                  padding: EdgeInsets.fromLTRB(14, i == 0 ? 6 : 10, 14, 5),
                  child: Row(
                    children: [
                      const Skeleton(width: 13, height: 13, radius: 3),
                      const SizedBox(width: 5),
                      Skeleton(width: 60 + (i * 18), height: 9, radius: 3),
                    ],
                  ),
                ),
                for (var r = 0; r < 2; r++)
                  Padding(
                    // Matches _OptionRow's own gutter + inner pad + row height,
                    // so a skeleton row occupies exactly what a model row will.
                    padding: const EdgeInsets.fromLTRB(
                      _rowGutter + _rowInnerPad,
                      5,
                      _rowInnerPad,
                      5,
                    ),
                    child: Row(
                      children: [
                        // Every row carries a glyph now, so the wait shows one
                        // too — an empty slot here would collapse into the label
                        // the moment the real icons landed.
                        const Skeleton(
                          width: _rowIconSlot,
                          height: _rowIconSlot,
                          radius: 4,
                        ),
                        const SizedBox(width: _rowIconGap),
                        Skeleton(
                          width: r.isEven ? 150 : 116,
                          height: 11,
                          radius: 3,
                        ),
                      ],
                    ),
                  ),
              ],
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

/// A muted line shown under a grid header when it can't list its models yet:
/// still loading, or unreachable. A ready grid serving nothing is filtered out
/// of the menu entirely, so [GridModelStatus.ready] never reaches here.
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
      // of rows, so it reads as a note under the grid rather than lining up as
      // one more thing you could pick. Spelled as the sum of the row's own parts
      // so it follows them; it used to be the hand-added answer, 29.
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
