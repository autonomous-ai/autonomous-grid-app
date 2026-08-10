import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/file_drag.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/app_menu_row.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/workspace/workspace_entries.dart';
import 'file_type_icon.dart';

/// Left indent added per folder deep. Narrower than the file dialog's 16: these
/// rows are drawn in a third of a panel and in a menu no wider, and four levels
/// in at 16 leaves no room for a name.
const double kFileTreeIndent = 12;

/// One file or folder in a tree.
///
/// Shared between the panel's own column and the tree behind a breadcrumb, so
/// the same folder looks the same in both — the indent, the chevron that turns,
/// and the file's type colour are the tree's language, not one widget's.
class FileTreeEntryRow extends StatelessWidget {
  const FileTreeEntryRow({
    super.key,
    required this.entry,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    required this.onTap,
    this.onContextMenu,
  });

  final WorkspaceEntry entry;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final VoidCallback onTap;

  /// Right-clicked, at that point on screen.
  ///
  /// The row reports rather than opens: one menu belongs to the *tree*, not one
  /// to each row. A `MenuAnchor` per row would put a focus scope on every line
  /// of a folder listing, and — worse — the rows are built by a lazy list that
  /// hands one row's element to another as you scroll, which is a menu opening
  /// over the wrong file.
  ///
  /// Null for every folder and wherever there is no conversation to add to, so
  /// no menu opens on either.
  final void Function(WorkspaceEntry entry, Offset globalPosition)?
  onContextMenu;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final isDir = entry.isDirectory;
    final row = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        hoverColor: AppSurface.hoverFill,
        splashFactory: NoSplash.splashFactory,
        child: Ink(
          decoration: BoxDecoration(
            color: isSelected ? AppSurface.selectedFill : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          padding: EdgeInsets.only(
            left: 6 + depth * kFileTreeIndent,
            right: 8,
            top: 5,
            bottom: 5,
          ),
          child: Row(
            children: [
              // The chevron slot: a folder fills it, a file leaves it blank so
              // its icon still lines up under its sibling folders'.
              SizedBox(
                width: 14,
                child: isDir
                    ? AnimatedRotation(
                        turns: isExpanded ? 0.25 : 0,
                        duration: AppMotion.hover,
                        curve: AppMotion.curve,
                        child: Icon(
                          LucideIcons.chevronRight300,
                          size: 13,
                          color: AppPalette.textFaint,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 2),
              // Folders stay the ink of the panel and files take their type's
              // colour. Colouring both would make the tree a mosaic with no
              // structure in it — the point of the hue is to pick a file out of
              // the folder it's in, which needs the folder to be the quiet one.
              if (isDir)
                Icon(
                  isExpanded
                      ? LucideIcons.folderOpen300
                      : LucideIcons.folder300,
                  size: 14,
                  color: AppPalette.textSecondary,
                )
              else
                FileTypeIcon(path: entry.name),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    // Selection is said by the wash *and* by the label stepping
                    // up, because at this size a wash alone is a shade the eye
                    // reads as hover. The icon stays its own colour throughout:
                    // a file that changed hue when you clicked it would look
                    // like a different kind of file.
                    fontWeight: isSelected ? AppFont.medium : FontWeight.w400,
                    color: isSelected ? AppPalette.textPrimary : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // A folder is neither draggable nor right-clickable, and for one reason: it
    // has nothing to attach. Both gestures end in the same "put this file on the
    // message", so what is true for the menu is true for the drag.
    if (isDir) return row;

    // Dragging a file onto the conversation attaches it — the same landing as
    // the menu's "Add to chat", reached by hand instead of by menu.
    //
    // A plain [Draggable], not a long-press one: the app never lets a mouse drag
    // scroll a list (Flutter's desktop default, and nothing here overrides it),
    // so there is no gesture to lose the race to, and a file that needs holding
    // down first would be the only thing on this desktop that does.
    final draggable = Draggable<FileDrag>(
      data: FileDrag(entry.path),
      // The chip rides under the pointer rather than where the row was grabbed:
      // it is a different size and shape from the row, so keeping the original
      // grab offset would leave it floating off at an angle to the cursor.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragChip(name: entry.name),
      // The row stays where it is, dimmed. Removing it would collapse the tree
      // under the pointer mid-drag, which reads as having dropped something.
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );

    final onContextMenu = this.onContextMenu;
    if (onContextMenu == null) return draggable;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          onContextMenu(entry, details.globalPosition),
      child: draggable,
    );
  }
}

/// What a file looks like while it is being carried: its own icon and name on a
/// small lifted surface.
///
/// Drawn in the app's overlay rather than in the tree, so it takes none of the
/// tree's context with it — hence the explicit [Material] and text style, and
/// the width cap, since a generated filename can run to a couple of hundred
/// characters and a chip that wide would cover the thing being aimed at.
class _DragChip extends StatelessWidget {
  const _DragChip({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppGlass.surfaceFill,
            borderRadius: BorderRadius.circular(8),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FileTypeIcon(path: name),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppPalette.textPrimary,
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

/// The tree's one right-click menu, wrapped around whatever draws its rows.
///
/// Opened by a row reporting where it was clicked — see
/// [FileTreeEntryRow.onContextMenu] for why the menu isn't the row's own.
class FileTreeContextMenu extends StatefulWidget {
  const FileTreeContextMenu({
    super.key,
    required this.onAddToChat,
    required this.builder,
  });

  final ValueChanged<String> onAddToChat;

  /// Draws the rows, given the callback to hand a right-click back with.
  final Widget Function(
    BuildContext context,
    void Function(WorkspaceEntry entry, Offset globalPosition) onContextMenu,
  )
  builder;

  @override
  State<FileTreeContextMenu> createState() => _FileTreeContextMenuState();
}

class _FileTreeContextMenuState extends State<FileTreeContextMenu> {
  final _menu = MenuController();

  /// The file the open menu is about. Held rather than passed to the rows,
  /// because by the time an item is tapped the row under it may have scrolled.
  String? _path;

  void _open(WorkspaceEntry entry, Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    setState(() => _path = entry.path);
    // At the pointer, not under the row: a menu answering a right-click has to
    // arrive at the thing that was clicked, and these rows are 24px tall in a
    // column a third of a panel wide.
    _menu.open(position: box.globalToLocal(globalPosition));
  }

  void _copyPath() {
    final path = _path;
    _menu.close();
    if (path == null) return;
    Clipboard.setData(ClipboardData(text: path));
    ToastScope.show(context, const ToastSpec(message: 'Path copied'));
  }

  void _add() {
    final path = _path;
    _menu.close();
    if (path != null) widget.onAddToChat(path);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: _menuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppMenuRow(
                icon: LucideIcons.link300,
                label: 'Copy path',
                onPressed: _copyPath,
              ),
              AppMenuRow(
                icon: LucideIcons.messageSquarePlus300,
                label: 'Add to chat',
                onPressed: _add,
              ),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) => widget.builder(context, _open),
    );
  }
}

const double _menuWidth = 176;

/// The line inside an expanded folder while its contents arrive, or after they
/// fail — indented to sit under that folder's children.
class FileTreeStatusRow extends StatelessWidget {
  const FileTreeStatusRow({
    super.key,
    required this.depth,
    required this.isError,
  });

  final int depth;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 6 + depth * kFileTreeIndent + 23,
        right: 8,
        top: 5,
        bottom: 5,
      ),
      child: isError
          ? Text(
              'Couldn’t open this folder.',
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
            )
          : const Align(
              alignment: Alignment.centerLeft,
              child: AppSpinner(size: SpinnerSize.small),
            ),
    );
  }
}
