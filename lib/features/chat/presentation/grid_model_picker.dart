import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../logic/grid_model_catalog.dart';

/// Called when the user picks a model: [grid] is the grid that serves it (which
/// becomes the active grid) and [option] is the chosen model / media mode.
typedef GridModelSelected =
    void Function(NetworkCredential grid, PlaygroundModelOption option);

/// The Chat header's unified grid + model control. A single compact button (like
/// the Agent picker) opens a searchable menu that lists every grid's models
/// grouped under the grid's name — picking one switches the active grid and the
/// model together, so the two old dropdowns collapse into one.
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
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
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

/// The compact button face: a model icon, the current model, and a caret.
class _TriggerButton extends StatelessWidget {
  const _TriggerButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.smart_toy_outlined, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        minimumSize: const WidgetStatePropertyAll(Size(0, 56)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        alignment: Alignment.centerLeft,
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
    // rows; no inner scrollable (which can't be intrinsic-measured) — the menu
    // scrolls itself when the list is tall.
    return SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchField(controller: _search, onChanged: _onQueryChanged),
          const Divider(height: 1),
          const SizedBox(height: 6),
          ..._rows(catalog, currentGridId),
          const SizedBox(height: 6),
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
