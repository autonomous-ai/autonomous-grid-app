import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart' show appMenuStyle;
import '../../../shared/widgets/menu_row.dart';
import '../../../shared/widgets/toolbar_pill.dart';
import '../logic/node_dashboard_view.dart';

/// The strip above the node cards: what they are ordered by, and which of them
/// are shown.
///
/// Three menus rather than a row of pills per value, because each answers a
/// single question with one answer in force at a time, and a grid can serve a
/// dozen models — a pill each would be a paragraph of controls above a dashboard
/// they are only there to point at.
///
/// **Given every online node, not the filtered ones.** The menus list what the
/// grid has, so narrowing to one model must not shrink the model menu to that
/// model — that is a filter you can enter and never leave.
class NodeDashboardToolbar extends ConsumerWidget {
  const NodeDashboardToolbar({super.key, required this.nodes});

  final List<OverviewNode> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final view = ref.watch(nodeDashboardViewProvider);
    final control = ref.read(nodeDashboardViewProvider.notifier);
    final models = nodeDashboardModels(nodes);
    final platforms = nodeDashboardPlatforms(nodes);

    // `Wrap`, so a narrow window drops a control to a second line instead of
    // overflowing the dialog — the app runs in a resizable desktop window.
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _PickerPill<NodeSortKey>(
          icon: LucideIcons.arrowDownWideNarrow,
          label: nodeSortLabel(view.sort),
          value: view.sort,
          // Wider than the filter menus because these rows carry a second line,
          // and [MenuRow] gives it one line with an ellipsis: at 268 "Most
          // tokens generated in the last 24h" lost its last word, which is the
          // word that says the figure is not all-time.
          width: 300,
          options: [
            for (final key in NodeSortKey.values)
              (
                value: key,
                label: nodeSortLabel(key),
                detail: nodeSortDetail(key),
              ),
          ],
          onPick: control.sortBy,
        ),
        // A menu that can only re-pick what is already in force narrows nothing,
        // so a grid serving one model is offered no model filter. The clear
        // button below is what keeps that from stranding anybody: a filter set
        // while the grid had more can always be undone, even after the machine
        // behind it went offline and took its menu with it.
        if (models.length > 1)
          _PickerPill<String?>(
            icon: LucideIcons.boxes,
            label: view.model == null
                ? 'All models'
                : modelLabelForKey(models, view.model!),
            value: view.model,
            options: [
              (value: null, label: 'All models', detail: null),
              for (final id in models)
                (value: id, label: modelLabel(id), detail: null),
            ],
            onPick: control.showModel,
          ),
        if (platforms.length > 1)
          _PickerPill<String?>(
            icon: LucideIcons.monitor,
            label: view.platform ?? 'All platforms',
            value: view.platform,
            options: [
              (value: null, label: 'All platforms', detail: null),
              for (final label in platforms)
                (value: label, label: label, detail: null),
            ],
            onPick: control.showPlatform,
          ),
        if (view.isFiltered)
          ToolbarPill(
            onTap: control.clearFilters,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.x, size: 13, color: AppPalette.textSecondary),
                const SizedBox(width: 5),
                Text(
                  'Show all',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFont.medium,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One option in a [_PickerPill] — its value, what to call it, and an optional
/// second line saying what picking it does.
typedef _Option<T> = ({T value, String label, String? detail});

/// A toolbar control: a pill saying what is in force, and the menu of what else
/// there is.
///
/// One widget for all three because they differ only in their options — three
/// hand-built [MenuAnchor]s beside each other is how a toolbar ends up with two
/// carets of different sizes and one menu that opens 2px further from its
/// button.
class _PickerPill<T> extends StatefulWidget {
  const _PickerPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.onPick,
    this.width = 236,
  });

  /// The glyph before the label — what the control is *about*, so the pills stay
  /// tellable apart when their labels are all short words.
  final IconData icon;

  /// What the pill prints: the option in force, not the question it answers. The
  /// question is the glyph's job; the row has no width to spend on "Sort by".
  final String label;

  final T value;
  final List<_Option<T>> options;
  final ValueChanged<T> onPick;

  /// How wide the menu draws. Its rows ellipsize inside it, so this is what
  /// decides whether a long model id survives.
  final double width;

  @override
  State<_PickerPill<T>> createState() => _PickerPillState<T>();
}

class _PickerPillState<T> extends State<_PickerPill<T>> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      style: appMenuStyle(),
      menuChildren: [
        for (final option in widget.options)
          MenuRow(
            label: option.label,
            detail: option.detail,
            width: widget.width,
            selected: option.value == widget.value,
            onTap: () {
              _menu.close();
              widget.onPick(option.value);
            },
          ),
      ],
      builder: (context, controller, _) => _PillButton(
        icon: widget.icon,
        label: widget.label,
        controller: controller,
      ),
    );
  }
}

/// The pill itself: glyph, the option in force, and a caret that turns over when
/// the menu is open.
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.controller,
  });

  final IconData icon;
  final String label;
  final MenuController controller;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final open = controller.isOpen;
    return ToolbarPill(
      active: open,
      onTap: () => open ? controller.close() : controller.open(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppPalette.textSecondary),
          const SizedBox(width: 6),
          // Capped rather than free: a model id can run to forty characters, and
          // an uncapped pill would push the controls beside it off the dialog.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          AnimatedRotation(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            turns: open ? 0.5 : 0,
            child: Icon(
              LucideIcons.chevronDown,
              size: 13,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
