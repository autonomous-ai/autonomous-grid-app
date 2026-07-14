import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
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
  static const _menuSize = Size(340, 370);

  final _menu = MenuController();

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize,
        alignEnd: true,
        preferAbove: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        visualDensity: VisualDensity.compact,
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
    return Tooltip(
      message: 'Choose which model answers',
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.textSecondary,
          backgroundColor: AppGlass.surfaceFill,
          side: BorderSide.none,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          minimumSize: const Size.fromHeight(32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
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
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
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
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: TextField(
        controller: controller,
        autofocus: true,
        onChanged: (_) => onChanged(),
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'Search models',
          prefixIcon: Icon(Icons.search, size: 18),
          border: OutlineInputBorder(),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.bolt, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 0.6,
                color: theme.colorScheme.onSurfaceVariant,
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
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(_modalityIcon(option.modality), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check, size: 18, color: scheme.primary),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _modalityIcon(PlaygroundModality modality) =>
      switch (modality) {
        PlaygroundModality.image => Icons.image_outlined,
        PlaygroundModality.video => Icons.movie_outlined,
        PlaygroundModality.text => Icons.smart_toy_outlined,
      };
}

/// A muted line shown under a grid header when it has nothing to list yet:
/// loading, offline, or serving no models.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.status});

  final GridModelStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (status) {
      GridModelStatus.loading => 'Loading models…',
      GridModelStatus.offline => 'Grid is offline',
      GridModelStatus.ready => 'No models available',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
