import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/files_path.dart';
import 'crumb_tree_menu.dart';
import 'file_type_icon.dart';

/// How long a crumb's panel survives the pointer leaving it.
///
/// The gap between a crumb and the panel under it is real space, and a pointer
/// crossing it is not a pointer leaving. Long enough to cross, short enough that
/// a menu you have walked away from is gone before you look back.
const Duration _closeDelay = Duration(milliseconds: 180);

/// Where the open file sits, from the chat's own folder down — `grid › lib ›
/// main.dart`.
///
/// The last crumb is the file and carries the ink, with its type's icon in front
/// of it so the bar says *what* is open as well as where; the folders above it
/// stay quiet.
///
/// Each crumb is also a way back up the folder: hovering one opens the folder
/// it stands in, and picking a file there opens it in a new tab — see
/// [CrumbTreeMenu]. Which crumb is open is tracked *here* rather than by each
/// crumb, so running the pointer along the path swaps one panel for the next
/// instead of leaving a trail of them.
class FilesBreadcrumb extends StatefulWidget {
  const FilesBreadcrumb({
    super.key,
    required this.crumbs,
    required this.onOpenInNewTab,
  });

  /// Root folder first, file last. Never empty — the root's own name stands
  /// alone before anything is picked, so the bar always says which folder this
  /// is.
  final List<FileCrumb> crumbs;

  /// Show this file, somewhere that isn't here. Null while the panel has no way
  /// to open a second tab, which also takes the crumb menus away: a tree you can
  /// look at but not act on is a tree that wastes the hover.
  final ValueChanged<String>? onOpenInNewTab;

  @override
  State<FilesBreadcrumb> createState() => _FilesBreadcrumbState();
}

class _FilesBreadcrumbState extends State<FilesBreadcrumb> {
  int? _open;
  Timer? _closing;

  @override
  void dispose() {
    _closing?.cancel();
    super.dispose();
  }

  void _hover(int index, bool inside) {
    _closing?.cancel();
    if (inside) {
      if (_open != index) setState(() => _open = index);
      return;
    }
    _closing = Timer(_closeDelay, () {
      if (mounted && _open == index) setState(() => _open = null);
    });
  }

  void _openFile(String path) {
    setState(() => _open = null);
    widget.onOpenInNewTab?.call(path);
  }

  /// The folder a crumb's panel lists: the one *above* it, so its siblings are
  /// on the list and stepping sideways is a click. The root crumb has nothing
  /// above it inside the project, so it lists itself.
  String _menuRoot(int i) =>
      i == 0 ? widget.crumbs[0].path : widget.crumbs[i - 1].path;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final crumbs = widget.crumbs;
    final last = crumbs.length - 1;
    final file = crumbs.length > 1 && !crumbs[last].isDirectory
        ? crumbs[last].path
        : null;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // A deep path scrolls rather than ellipsing, and starts at its end: the
        // file's own name is the part worth reading, and the part an ellipsis
        // would eat.
        reverse: true,
        // Reversing is also what pushed a *short* path to the right-hand end of
        // the bar, hard against the buttons, which is the misalignment this
        // fixes: with nothing to scroll, a reversed viewport parks its content
        // at the trailing edge. Holding the row to at least the viewport's width
        // gives it somewhere to start from, so short paths sit at the left where
        // they belong and long ones still arrive scrolled to the file.
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            children: [
              for (var i = 0; i <= last; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Icon(
                      LucideIcons.chevronRight300,
                      size: 13,
                      color: AppPalette.textFaint,
                    ),
                  ),
                _Crumb(
                  crumb: crumbs[i],
                  isLast: i == last,
                  // The root's mark only when there is no file to speak for the
                  // bar; a coloured file icon at the far left, six crumbs from
                  // the name it belongs to, says nothing.
                  leadRoot: i == 0 && file == null,
                  file: i == last ? file : null,
                  menu: widget.onOpenInNewTab == null
                      ? null
                      : (
                          root: _menuRoot(i),
                          // A folder crumb opens *inside* its parent's list; a
                          // file has nothing to open.
                          expand: i > 0 && crumbs[i].isDirectory
                              ? crumbs[i].path
                              : null,
                          isOpen: _open == i,
                          onHover: (inside) => _hover(i, inside),
                        ),
                  onOpenFile: _openFile,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What a crumb needs from the breadcrumb to put a folder behind itself.
typedef _Menu = ({
  String root,
  String? expand,
  bool isOpen,
  ValueChanged<bool> onHover,
});

/// One step: its mark, its name, and — when the panel can act on a pick — the
/// folder behind it.
class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.crumb,
    required this.isLast,
    required this.leadRoot,
    required this.file,
    required this.menu,
    required this.onOpenFile,
  });

  final FileCrumb crumb;
  final bool isLast;
  final bool leadRoot;
  final String? file;
  final _Menu? menu;
  final ValueChanged<String> onOpenFile;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final file = this.file;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (file != null) ...[
          FileTypeIcon(path: file, size: 13),
          const SizedBox(width: 5),
        ] else if (leadRoot) ...[
          Icon(
            LucideIcons.folder300,
            size: 13,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 5),
        ],
        Text(
          crumb.name,
          maxLines: 1,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isLast ? AppFont.medium : FontWeight.w400,
            color: isLast ? AppPalette.textPrimary : AppPalette.textSecondary,
          ),
        ),
      ],
    );

    final menu = this.menu;
    if (menu == null) return label;
    return CrumbTreeMenu(
      root: menu.root,
      expand: menu.expand,
      highlight: crumb.path,
      isOpen: menu.isOpen,
      onHover: menu.onHover,
      onOpenFile: onOpenFile,
      // The hover target is the label plus a little around it, so the pointer
      // has somewhere to rest between two crumbs without the panel flickering
      // shut. The wash under it is what says the crumb answers to a pointer at
      // all — the same wash a menu row takes.
      child: _CrumbSurface(isOpen: menu.isOpen, child: label),
    );
  }
}

/// The crumb's own hit area and its hover wash.
class _CrumbSurface extends StatefulWidget {
  const _CrumbSurface({required this.isOpen, required this.child});

  final bool isOpen;
  final Widget child;

  @override
  State<_CrumbSurface> createState() => _CrumbSurfaceState();
}

class _CrumbSurfaceState extends State<_CrumbSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.hover,
        curve: AppMotion.curve,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: _hovered || widget.isOpen
              ? AppSurface.hoverFill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: widget.child,
      ),
    );
  }
}
