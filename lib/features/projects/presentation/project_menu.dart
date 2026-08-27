import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/project.dart';
import '../logic/project_folder_status.dart';

const _menuWidth = 208.0;

/// One standard menu row: 1px gutter + 8px inset, a 16px glyph/label line, then
/// the same back again. Must stay in step with what [_ProjectMenuItem] actually
/// builds — the menu is positioned by summing these, so a row that measures
/// taller than this floats the whole panel off its button.
const _rowHeight = 34.0;
const _dividerHeight = 9.0;

/// Matches the vertical padding in [appMenuStyle] — these were 6 vs 5 once, and
/// the menu drifted by exactly that difference.
const _menuPadding = 5.0;

/// What the menu will measure given what it's about to show — the reveal row is
/// dropped when the folder is gone. Summed rather than guessed so
/// [anchoredMenuPosition] lands the menu on the button instead of near it.
///
/// Four rows above the divider (pin, reveal, rename, change folder), one below.
Size _menuSize({required bool reveal}) => Size(
  _menuWidth,
  _menuPadding * 2 +
      _rowHeight * (reveal ? 4 : 3) +
      _dividerHeight +
      _rowHeight,
);

/// The "…" overflow menu on a project row: pin it to the top, reveal its folder,
/// rename it, point it at another folder, or take it off the list. Mirrors the app's MenuAnchor pattern so it
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

  /// Move the project to another folder, keeping its chats.
  ///
  /// The repair for a folder deleted or moved in Finder: the path is the agent's
  /// working directory, so until it names somewhere real every turn in this
  /// project fails before the agent starts (see [projectFolderGoneMessage]).
  /// Removing the project was the only way out before this, and that takes its
  /// chats' project with it.
  Future<void> _changeFolder() async {
    _menu.close();
    final path = await getDirectoryPath(confirmButtonText: 'Use folder');
    if (path == null || path == _project.path) return;
    ref.read(projectsProvider.notifier).setPath(_project.id, path);
    // The badge and the "Show in Finder" row both read the cached probe, and the
    // folder that was missing a second ago is exactly the one this just fixed.
    revalidateProjectFolders(ref);
    if (!mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: '${_project.name} now opens in $path',
        severity: ToastSeverity.success,
      ),
    );
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
    final reveal = !watchProjectMissing(ref, _project);
    return MenuAnchor(
      controller: _menu,
      // The shared surface, not a hand-rolled one. This menu opens over the
      // sidebar, and AppGlass.surfaceFill sits within 1.02:1 of a raised block
      // — in light both are white, so the panel had no edge at all.
      // appMenuStyle() lifts it clear on both grounds (§5).
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuPadding),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      menuChildren: [
        _ProjectMenuContent(
          pinned: _project.pinned,
          reveal: reveal,
          onPin: _togglePin,
          onReveal: _reveal,
          onRename: _rename,
          onChangeFolder: _changeFolder,
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
    required this.onChangeFolder,
    required this.onRemove,
  });

  final bool pinned;
  final bool reveal;
  final VoidCallback onPin;
  final VoidCallback onReveal;
  final VoidCallback onRename;
  final VoidCallback onChangeFolder;
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
          // Shown whether or not the folder is there: moving a project that
          // still has its folder is the same action, and a row that only
          // appears once something has broken is one nobody knows exists.
          _ProjectMenuItem(
            icon: LucideIcons.folderInput300,
            label: 'Change folder…',
            onPressed: onChangeFolder,
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

/// One row of the menu, built to the standard recipe in §5 of the design system:
/// a 6px gutter so hover reads as an inset pill rather than a full-bleed band,
/// radius 8, no ink ripple, and a 16px leading slot that keeps labels aligned.
///
/// Hand-rolled rather than a [MenuItemButton] because the app has no
/// `menuButtonTheme`, so a bare one takes Material's M3 defaults and lands wrong
/// on four counts at once: radius 0, 14pt `labelLarge` text, a grey `onSurface`
/// 8% hover, and a ripple every other menu here has turned off.
///
/// Stateful for its own hover: the glyph has to climb to [AppPalette.textPrimary]
/// under the pointer. An icon that stays dim while the cursor sits on it reads as
/// decoration, and nothing above this row tracks hover per-row to do it for us.
class _ProjectMenuItem extends StatefulWidget {
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
  State<_ProjectMenuItem> createState() => _ProjectMenuItemState();
}

class _ProjectMenuItemState extends State<_ProjectMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Lives in the MenuAnchor's overlay, so it watches for itself.
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    // Danger rows are already red at rest, so they deepen rather than climb.
    final tint = widget.danger
        ? error
        : (_hovered ? AppPalette.textPrimary : AppPalette.textSecondary);

    return Padding(
      // The 6px gutter, and the row height the menu's own size constant is
      // summed from — vertical 1 here plus 8+8 inside keeps it at _rowHeight.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onPressed,
          onHover: (hovered) => setState(() => _hovered = hovered),
          borderRadius: BorderRadius.circular(8),
          hoverColor: widget.danger
              ? error.withValues(alpha: 0.09)
              : AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                // Fixed 16px slot: the icons here differ in width, and without
                // it every label would start at a slightly different column.
                SizedBox(
                  width: 16,
                  child: Icon(widget.icon, size: 16, color: tint),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.danger ? error : AppPalette.textPrimary,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
  final name = await showAppDialog<String>(
    context: context,
    builder: (_) => _RenameProjectDialog(project: project),
  );
  if (name != null) {
    ref.read(projectsProvider.notifier).rename(project.id, name);
  }
}

/// The rename form. Stateful so the confirm button can follow what's typed:
/// [ProjectsNotifier.rename] drops a blank name on the floor, so a lit-up
/// "Rename" over an empty field is a button that promises something it won't do.
class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({required this.project});

  final Project project;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.project.name,
  );

  @override
  void initState() {
    super.initState();
    // Listen to the controller rather than leaning on the field's `onChanged`:
    // text can arrive without the field ever firing that callback — the
    // controller being set programmatically, or `enterText` in a widget test —
    // and then the confirm button would still be reading the previous value.
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() => setState(() {});

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    super.dispose();
  }

  bool get _canRename {
    final trimmed = _name.text.trim();
    return trimmed.isNotEmpty && trimmed != widget.project.name;
  }

  void _submit() {
    if (!_canRename) return;
    Navigator.of(context).pop(_name.text);
  }

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // Same shell as the app's other dialogs (see `prompt_dialog.dart`): the
    // stock AlertDialog brings Material's surface tint and a tighter radius,
    // neither of which belongs to this design system.
    return AlertDialog(
      // `AppSurface.surfaceFill`, not `AppPalette.windowBg`: windowBg *is* the
      // page this dialog opens over, so a dialog wearing it is the page's own
      // colour — 1.000:1, an edgeless slab. A dialog is the topmost layer, so
      // it takes the lifted surface (#202020, 1.090:1 against the dark page)
      // per §2's stack. That margin is thin since the page moved to #181818,
      // which is why the shadow does the lifting here and the fill only helps.
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rename project',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Only the label changes — the folder on disk stays where it is.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            // LabeledField, not a bare TextField with `labelText`: Material
            // floats that label into the field's rim, which rule 2 of the
            // design system rules out — labels sit above the control.
            LabeledField(
              label: 'Name',
              controller: _name,
              hint: widget.project.name,
              autofocus: true,
              // The field sits on the dialog's *raised* surface, not the page,
              // so the default cardBg fill is the wrong ground: measured on
              // #202020 it lands at 1.023:1 and the unfocused box dissolves
              // into the dialog. AppCard.inset is the recessed token for
              // exactly this — 1.09:1 there. Light is the other way round
              // (cardBg 1.11:1 beats inset's 1.073:1), so this picks per theme
              // rather than committing to one value that only works in dark.
              fill: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
              // No onChanged: the controller listener above already rebuilds.
              // Enter confirms, as it did before this dialog was rebuilt.
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        // A disabled button with no reason attached reads as broken — this one
        // greys out both for a blank name and for a name that hasn't actually
        // changed, and the second case looks identical to "nothing happened".
        Tooltip(
          message: _name.text.trim().isEmpty
              ? 'Give the project a name'
              : _canRename
              ? 'Rename the project'
              : "That's already its name",
          child: FilledButton(
            onPressed: _canRename ? _submit : null,
            child: const Text('Rename'),
          ),
        ),
      ],
    );
  }
}

/// Confirms taking [project] off the list. Returns true only when the user says
/// so — the folder and its files stay exactly where they are either way.
Future<bool> confirmRemoveProject(BuildContext context, Project project) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      // Reads AppPalette tokens — follow theme flips.
      AppTheme.watch(context);
      final theme = Theme.of(context);
      // Same shell as the rename dialog above: the two open from one menu, so
      // a stock AlertDialog next to a styled one reads as a bug.
      return AlertDialog(
        // The lifted surface, not windowBg — see the rename dialog above.
        backgroundColor: AppGlass.surfaceFill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
        contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
        actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
        title: Text(
          'Remove "${project.name}"?',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: 460,
          child: Text(
            'The folder and its files stay exactly where they are — this only '
            'takes it off your list, and its chats move out of the project.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          // Tinted to the error colour: this one takes something away, and in
          // the default fill it looked identical to the benign confirm sitting
          // one menu item above it.
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              // Not `colorScheme.onError`: neither scheme sets it, so it falls
              // back to Material's, and on the dark palette's #F2544B that
              // default (#690005) measures 3.83:1 — under the 4.5:1 body text
              // needs. White is worse there (3.42:1); black clears it at 6.15:1.
              // Light's #B3261E is the opposite case, so this has to switch.
              foregroundColor: AppTheme.isDark
                  ? Colors.black
                  : theme.colorScheme.onError,
            ),
            child: const Text('Remove'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
