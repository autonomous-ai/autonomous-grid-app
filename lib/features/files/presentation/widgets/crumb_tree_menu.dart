import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/anchored_menu_position.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/workspace/workspace_entries.dart';
import '../../../../shared/workspace/workspace_tree.dart';
import 'file_tree_rows.dart';

const double _menuWidth = 268;

/// Fixed, and taller than [AppControl.menuMaxHeight]'s 240: this panel is a
/// place to look around in, not a list of five commands. It never grows with the
/// folder — a menu that is short for `resources` and floor-to-ceiling for
/// `node_modules` would jump every time the pointer moved one crumb.
const double _menuHeight = 340;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: measured, the tree draws 5px below the panel
/// edge, so a cap set to the tree's height alone leaves the panel 10px short of
/// its contents.
const double _menuPadding = 5;

/// What the panel actually measures, which is what has to be capped *and* what
/// [anchoredMenuPosition] has to be told — the two drifting apart is how a menu
/// ends up floating off the thing it belongs to.
const double _panelHeight = _menuHeight + _menuPadding * 2;

const Size _menuSize = Size(_menuWidth, _panelHeight);

/// A breadcrumb step, with the folder behind it one hover away.
///
/// The crumbs used not to be interactive at all, on the grounds that the tree
/// beside them was how you moved. That holds while the tree is *there* — it can
/// be hidden now, and either way the path already on screen is the most direct
/// way to say "somewhere else near here". So each crumb opens the folder it
/// stands in, and picking a file from it opens that file in a **new tab**: you
/// went looking sideways, so the thing you were reading is still worth keeping.
class CrumbTreeMenu extends StatefulWidget {
  const CrumbTreeMenu({
    super.key,
    required this.root,
    required this.expand,
    required this.highlight,
    required this.isOpen,
    required this.onHover,
    required this.onOpenFile,
    required this.child,
  });

  /// The folder the menu lists — the crumb's parent, so its siblings are there
  /// too and moving sideways is one click.
  final String root;

  /// The crumb's own folder, opened when the panel appears. Null for the crumb
  /// that *is* [root] (there is nothing above it to show it inside of) and for
  /// the file at the end of the path.
  final String? expand;

  /// The crumb's own path, marked so "you are here" survives a scroll.
  final String highlight;

  final bool isOpen;

  /// True when the pointer is over the crumb or the panel it opened. The
  /// breadcrumb owns which crumb is open, so that moving along the path swaps
  /// one panel for the next instead of stacking them.
  final ValueChanged<bool> onHover;

  final ValueChanged<String> onOpenFile;

  /// The crumb itself — the label, and the chevron before it.
  final Widget child;

  @override
  State<CrumbTreeMenu> createState() => _CrumbTreeMenuState();
}

class _CrumbTreeMenuState extends State<CrumbTreeMenu> {
  final _menu = MenuController();

  /// The crumb's own box, which is what the panel is placed against.
  ///
  /// A key rather than the builder's context: [MenuAnchor] wraps a row that
  /// scrolls sideways, and the anchor has to be measured at the moment it opens
  /// rather than wherever it was when this widget was built.
  final _anchor = GlobalKey();

  @override
  void didUpdateWidget(CrumbTreeMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen == oldWidget.isOpen) return;
    // After the frame, never during it: opening a menu inserts into the overlay,
    // which is a build of its own and cannot start inside this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = _anchor.currentContext;
      if (widget.isOpen && !_menu.isOpen && anchor != null) {
        _menu.open(
          position: anchoredMenuPosition(
            anchor,
            menuSize: _menuSize,
            margin: 8,
            gap: 6,
            maxHeight: _panelHeight,
          ),
        );
      } else if (!widget.isOpen && _menu.isOpen) {
        _menu.close();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        maximumSize: const WidgetStatePropertyAll(
          Size.fromHeight(_panelHeight),
        ),
      ),
      menuChildren: [
        // The panel counts as part of the crumb for hover: the pointer moving
        // down into the tree must not be the thing that closes it.
        MouseRegion(
          onEnter: (_) => widget.onHover(true),
          onExit: (_) => widget.onHover(false),
          child: _CrumbTree(
            root: widget.root,
            expand: widget.expand,
            highlight: widget.highlight,
            onOpenFile: widget.onOpenFile,
          ),
        ),
      ],
      builder: (context, controller, child) => MouseRegion(
        onEnter: (_) => widget.onHover(true),
        onExit: (_) => widget.onHover(false),
        child: KeyedSubtree(key: _anchor, child: widget.child),
      ),
    );
  }
}

/// The folder itself, in a box that never changes size.
class _CrumbTree extends ConsumerStatefulWidget {
  const _CrumbTree({
    required this.root,
    required this.expand,
    required this.highlight,
    required this.onOpenFile,
  });

  final String root;
  final String? expand;
  final String highlight;
  final ValueChanged<String> onOpenFile;

  @override
  ConsumerState<_CrumbTree> createState() => _CrumbTreeState();
}

class _CrumbTreeState extends ConsumerState<_CrumbTree> {
  /// Opened folders, kept here rather than in the tab's own state: this is a
  /// look around, and what you opened while looking should not rearrange the
  /// column you go back to.
  late final Set<String> _expanded = {?widget.expand};

  void _toggle(String path) => setState(() {
    if (!_expanded.remove(path)) _expanded.add(path);
  });

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final entries = ref.watch(
      workdirEntriesProvider((path: widget.root, hidden: true)),
    );
    return SizedBox(
      width: _menuWidth,
      height: _menuHeight,
      child: switch (entries) {
        AsyncData(:final value) when value.isEmpty => const _Note(
          'This folder is empty.',
        ),
        AsyncData(:final value) => _Rows(
          rows: flattenWorkspaceTree(
            rootEntries: value,
            expanded: _expanded,
            childrenOf: (path) =>
                ref.watch(workdirEntriesProvider((path: path, hidden: true))),
          ),
          highlight: widget.highlight,
          onToggle: _toggle,
          onOpenFile: widget.onOpenFile,
        ),
        AsyncError() => const _Note('Could not read this folder.'),
        _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
      },
    );
  }
}

class _Rows extends StatefulWidget {
  const _Rows({
    required this.rows,
    required this.highlight,
    required this.onToggle,
    required this.onOpenFile,
  });

  final List<WorkspaceRow> rows;
  final String highlight;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onOpenFile;

  @override
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  /// Held so the scrollbar can be told which list it belongs to — `Scrollbar`
  /// asserts on a visible thumb with no controller, and a thumb that comes and
  /// goes is one you can't take hold of.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    // Always out, unlike the rest of the app: this panel is a fixed 340px over
    // a folder that can hold hundreds, so the bar is how you cover that ground
    // in one drag. Everywhere else the list *is* the pane and fading the thumb
    // in on scroll keeps a short list from wearing furniture — here the list is
    // a window onto something much longer, and a thumb you have to make appear
    // before you can grab it is one you scroll past instead.
    thumbVisibility: true,
    child: ListView.builder(
      controller: _scroll,
      // The panel's own vertical padding is the menu style's; this is the side
      // gutter that keeps a row's hover reading as an inset pill. The right
      // side is wider by the thumb's own 6px so a long name runs behind it
      // rather than under it.
      padding: const EdgeInsets.only(left: 5, right: 11),
      itemCount: widget.rows.length,
      itemBuilder: (context, i) => switch (widget.rows[i]) {
        WorkspaceEntryRow(:final entry, :final depth, :final isExpanded) =>
          FileTreeEntryRow(
            entry: entry,
            depth: depth,
            isExpanded: isExpanded,
            isSelected: entry.path == widget.highlight,
            // A folder opens in place — you are still looking. A file is a
            // decision, and it leaves with you.
            onTap: () => entry.isDirectory
                ? widget.onToggle(entry.path)
                : widget.onOpenFile(entry.path),
          ),
        WorkspaceStatusRow(:final depth, :final isError) => FileTreeStatusRow(
          depth: depth,
          isError: isError,
        ),
      },
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
        ),
      ),
    );
  }
}
