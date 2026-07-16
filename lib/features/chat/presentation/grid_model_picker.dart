import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../logic/grid_model_catalog.dart';

/// Called when the user picks a model: [grid] is the grid that serves it (which
/// becomes the active grid) and [option] is the chosen model / media mode.
typedef GridModelSelected =
    void Function(NetworkCredential grid, PlaygroundModelOption option);

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
}

/// The pill that sits in the composer: the model that will answer, and a caret.
/// Quiet by design — it's a property of the message, not a call to action.
class _TriggerButton extends StatelessWidget {
  const _TriggerButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppPalette/AppGlass tokens — follow theme flips
    return Tooltip(
      message: 'Choose which model answers',
      child: OutlinedButton(
        onPressed: onTap,
        // Deliberately a pill, not a push button: it names the current model
        // inside the composer's chrome, so it stays stadium-shaped and filled
        // rather than taking the app's bordered-button shape.
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.textPrimary,
          backgroundColor: Colors.transparent,
          side: BorderSide.none,
          shape: const StadiumBorder(),
          padding: AppControl.paddingSmall,
          minimumSize: const Size.fromHeight(AppControl.height),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              child: Column(
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
      rows.add(_GroupHeader(name: group.grid.name));
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
    if (rows.isEmpty) rows.add(const _InfoRow(status: GridModelStatus.ready));
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
  const _GroupHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          // The bolt is the grid's mark — it earns the brand gold here, where it
          // labels a grid, rather than the same grey as the name beside it.
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
                color: AppPalette.textFaint,
              ),
            ),
          ),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppSurface.hoverFill,
          child: Ink(
            decoration: BoxDecoration(
              // Same wash + ticked-disc language as the approval menu, so "the
              // one in force" looks the same wherever the composer says it.
              color: selected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                // Only the exceptions get a glyph. Text is the fallback for every
                // model that isn't image or video, so a robot beside each of them
                // just said "this is a model" in a list of models — a column of
                // identical icons that told the rows apart not at all. Image and
                // video are the rare ones, and there the icon is the whole point.
                SizedBox(
                  width: 16,
                  child: option.modality == PlaygroundModality.text
                      ? null
                      : Icon(
                          _modalityIcon(option.modality),
                          size: 16,
                          color: selected
                              ? AppPalette.accentMuted
                              : AppPalette.textFaint,
                        ),
                ),
                const SizedBox(width: 9),
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

  /// Only reached for the modalities that get a glyph — text rows render none,
  /// so it has no icon to name here.
  static IconData? _modalityIcon(PlaygroundModality modality) =>
      switch (modality) {
        PlaygroundModality.image => Icons.image_outlined,
        PlaygroundModality.video => Icons.movie_outlined,
        PlaygroundModality.text => null,
      };
}

/// A muted line shown under a grid header when it has nothing to list yet:
/// loading, offline, or serving no models.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.status});

  final GridModelStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    final message = switch (status) {
      GridModelStatus.loading => 'Loading models…',
      GridModelStatus.offline => 'Grid is offline',
      GridModelStatus.ready => 'No models available',
    };
    return Padding(
      // Indented to the option rows' text, not their icon: this is the absence
      // of rows, so it reads as a note under the grid rather than lining up as
      // one more thing you could pick.
      padding: const EdgeInsets.fromLTRB(29, 2, 15, 8),
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
