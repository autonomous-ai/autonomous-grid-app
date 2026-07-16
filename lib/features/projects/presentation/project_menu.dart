import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/project.dart';

const _menuWidth = 208.0;
const _rowHeight = 34.0;
const _dividerHeight = 9.0;
const _menuPadding = 6.0;

/// What the menu will measure given what it's about to show — the reveal row is
/// dropped when the folder is gone. Summed rather than guessed so
/// [anchoredMenuPosition] lands the menu on the button instead of near it.
Size _menuSize({required bool reveal}) => Size(
  _menuWidth,
  _menuPadding * 2 +
      _rowHeight * (reveal ? 3 : 2) +
      _dividerHeight +
      _rowHeight,
);

/// The "…" overflow menu on a project row: pin it to the top, reveal its folder,
/// rename it, or take it off the list. Mirrors the app's MenuAnchor pattern so it
/// reads like every other menu (the task-power and account menus).
class ProjectMenuButton extends ConsumerStatefulWidget {
  const ProjectMenuButton({super.key, required this.project});

  final Project project;

  @override
  ConsumerState<ProjectMenuButton> createState() => _ProjectMenuButtonState();
}

class _ProjectMenuButtonState extends ConsumerState<ProjectMenuButton> {
  final _menu = MenuController();

  Project get _project => widget.project;

  void _togglePin() {
    _menu.close();
    ref
        .read(projectsProvider.notifier)
        .setPinned(_project.id, !_project.pinned);
  }

  Future<void> _reveal() async {
    _menu.close();
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(_project.path);
    if (opened || !mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: "Couldn't open ${_project.path}",
        severity: ToastSeverity.error,
      ),
    );
  }

  Future<void> _rename() async {
    _menu.close();
    await showRenameProjectDialog(context, ref, _project);
  }

  Future<void> _remove() async {
    _menu.close();
    final ok = await confirmRemoveProject(context, _project);
    if (ok) ref.read(projectsProvider.notifier).remove(_project.id);
  }

  void _toggle(BuildContext context, MenuController controller, Size size) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    // Right-aligned: the button sits at the row's trailing edge, so a menu that
    // grew rightwards from it would hang off the rail.
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: size,
        margin: 8,
        gap: 6,
        alignEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The trigger tints from a global the element tree can't track, so subscribe
    // to the brightness — the menu's *contents* subscribe separately, in
    // _ProjectMenuContent, since they live in an overlay this build can't reach.
    AppTheme.watch(context);
    final reveal = _project.exists;
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuPadding),
        ),
        backgroundColor: WidgetStatePropertyAll(AppGlass.surfaceFill),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppGlass.hair),
          ),
        ),
      ),
      menuChildren: [
        _ProjectMenuContent(
          pinned: _project.pinned,
          reveal: reveal,
          onPin: _togglePin,
          onReveal: _reveal,
          onRename: _rename,
          onRemove: _remove,
        ),
      ],
      builder: (context, controller, _) => _MenuTrigger(
        onTap: () => _toggle(context, controller, _menuSize(reveal: reveal)),
      ),
    );
  }
}

/// The menu's rows. Lives in the MenuAnchor's overlay — detached from the row, so
/// a theme flip won't reach it top-down; it depends on the brightness directly so
/// an open menu re-colours the instant the theme changes.
class _ProjectMenuContent extends StatelessWidget {
  const _ProjectMenuContent({
    required this.pinned,
    required this.reveal,
    required this.onPin,
    required this.onReveal,
    required this.onRename,
    required this.onRemove,
  });

  final bool pinned;
  final bool reveal;
  final VoidCallback onPin;
  final VoidCallback onReveal;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProjectMenuItem(
            icon: pinned ? LucideIcons.pinOff300 : LucideIcons.pin300,
            label: pinned ? 'Unpin project' : 'Pin project',
            onPressed: onPin,
          ),
          if (reveal)
            _ProjectMenuItem(
              icon: LucideIcons.folderOpen300,
              label: 'Show in Finder',
              onPressed: onReveal,
            ),
          _ProjectMenuItem(
            icon: LucideIcons.pencilLine300,
            label: 'Rename project',
            onPressed: onRename,
          ),
          // The one destructive entry, fenced off so it can't be hit on the way
          // to Rename.
          const _ProjectMenuDivider(),
          _ProjectMenuItem(
            icon: LucideIcons.trash2300,
            label: 'Remove from Grid',
            onPressed: onRemove,
            danger: true,
          ),
        ],
      ),
    );
  }
}

class _ProjectMenuItem extends StatelessWidget {
  const _ProjectMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Tints the row red and gives it a red hover wash — for [_remove] alone.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final tint = danger ? error : AppPalette.textSecondary;
    return MenuItemButton(
      onPressed: onPressed,
      requestFocusOnHover: false,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        overlayColor: WidgetStatePropertyAll(
          danger ? error.withValues(alpha: 0.09) : AppSurface.hoverFill,
        ),
        // Pinned, not a minimum: the menu is positioned by summing these heights,
        // and Flutter defaults visualDensity to *compact* on desktop — which
        // would take 8px off every row and float the menu clear of the button.
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, _rowHeight)),
        maximumSize: const WidgetStatePropertyAll(
          Size(double.infinity, _rowHeight),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: danger ? error : AppPalette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectMenuDivider extends StatelessWidget {
  const _ProjectMenuDivider();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: _dividerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, thickness: 1, color: AppPalette.divider),
      ),
    );
  }
}

/// The "…" itself: a quiet target that warms and fills under the pointer, so it
/// says "click me" the way the account pill does.
class _MenuTrigger extends StatefulWidget {
  const _MenuTrigger({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_MenuTrigger> createState() => _MenuTriggerState();
}

class _MenuTriggerState extends State<_MenuTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Semantics(
      button: true,
      label: 'Project options',
      child: Tooltip(
        message: 'Project options',
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: Icon(
                LucideIcons.ellipsis300,
                size: 17,
                color: _hovered
                    ? AppPalette.textPrimary
                    : AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renames [project] after asking for the new name. The folder on disk never
/// moves — only the label. Cancelling, or leaving it blank, changes nothing.
Future<void> showRenameProjectDialog(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final controller = TextEditingController(text: project.name);
  try {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name != null) {
      ref.read(projectsProvider.notifier).rename(project.id, name);
    }
  } finally {
    // After the frame, not the moment `showDialog` returns: the dialog is still
    // animating out and rebuilds its TextField on the way, which would read a
    // controller disposed out from under it.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}

/// Confirms taking [project] off the list. Returns true only when the user says
/// so — the folder and its files stay exactly where they are either way.
Future<bool> confirmRemoveProject(BuildContext context, Project project) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove "${project.name}"?'),
      content: const Text(
        'The folder and its files stay exactly where they are — this only '
        'takes it off your list, and its chats move out of the project.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
