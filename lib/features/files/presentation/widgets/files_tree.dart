import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/workspace/workspace_entries.dart';
import '../../../../shared/workspace/workspace_tree.dart';
import '../../logic/files_browser.dart';
import '../../logic/files_filter.dart';
import 'file_tree_rows.dart';

/// The project's folders and files, in the panel's side column: a filter box
/// over a tree that opens in place.
///
/// Each folder's contents are read only when it's opened, so a repository with
/// a hundred thousand files in it costs nothing until asked. That laziness is
/// also why the filter can only match what has been opened — see
/// [filterWorkspaceRows].
class FilesTree extends ConsumerWidget {
  const FilesTree({
    super.key,
    required this.tabId,
    required this.root,
    required this.onOpen,
    required this.onAddToChat,
  });

  final String tabId;

  /// The project folder the tree is rooted at. It never reaches above this.
  final String root;

  /// A file was picked — the panel shows it.
  final ValueChanged<WorkspaceEntry> onOpen;

  /// A file was chosen out of its right-click menu to ride on the next message.
  /// Null when there is no conversation to put it in, and then no menu opens.
  final ValueChanged<String>? onAddToChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(filesBrowserProvider(tabId));
    final entries = ref.watch(
      workdirEntriesProvider((path: root, hidden: true)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: _FilterField(
            value: state.query,
            onChanged: (q) =>
                ref.read(filesBrowserProvider(tabId).notifier).setQuery(q),
          ),
        ),
        Expanded(
          child: switch (entries) {
            AsyncData(:final value) when value.isEmpty => const _Message(
              'This folder is empty.',
            ),
            AsyncData(:final value) => _Rows(
              // Each expanded folder is read lazily here; watching happens in
              // build, so a folder's children arrive when the user opens it.
              rows: filterWorkspaceRows(
                flattenWorkspaceTree(
                  rootEntries: value,
                  expanded: state.expanded,
                  childrenOf: (path) => ref.watch(
                    workdirEntriesProvider((path: path, hidden: true)),
                  ),
                ),
                state.query,
              ),
              filtered: state.query.trim().isNotEmpty,
              selected: state.selected,
              onToggle: (path) => ref
                  .read(filesBrowserProvider(tabId).notifier)
                  .toggleFolder(path),
              onOpen: onOpen,
              onAddToChat: onAddToChat,
            ),
            AsyncError() => const _Message(
              'Could not read this folder. It may have been moved or deleted.',
            ),
            _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
          },
        ),
      ],
    );
  }
}

/// The filter box. Its own widget so the field keeps its controller across the
/// tree's rebuilds — rebuilding a `TextField` with a fresh controller every
/// time a folder opens would drop the cursor mid-word.
class _FilterField extends StatefulWidget {
  const _FilterField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<_FilterField> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void initState() {
    super.initState();
    // The clear button comes and goes with the text, and the text changes under
    // the keyboard rather than under this widget — so the field itself has to
    // say when it has something in it.
    _controller.addListener(_onTyped);
  }

  void _onTyped() => setState(() {});

  void _clear() {
    _controller.clear();
    widget.onChanged('');
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTyped)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final hasText = _controller.text.isNotEmpty;
    return SizedBox(
      // [AppControl.heightField], the token that already exists for exactly
      // this — a search field at the head of a list column. It was on
      // [AppControl.heightSmall]'s 28, which is a chip in a toolbar row: a
      // control sized to be *hit* rather than typed in, and it read as cramped
      // against the tree it heads.
      height: AppControl.heightField,
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        style: const TextStyle(fontSize: 12.5),
        decoration: labeledFieldDecoration('Filter files…').copyWith(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          prefixIcon: Icon(
            LucideIcons.search300,
            size: 14,
            color: AppPalette.textFaint,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
          // Shown whenever there is something to clear — including when the
          // filter matches nothing, which is exactly when the user most needs
          // the way out of it.
          suffixIcon: hasText ? _ClearButton(onPressed: _clear) : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 28),
        ),
      ),
    );
  }
}

/// The × that empties the filter.
///
/// Its own widget so it owns its hover: inside a `TextField`'s decoration there
/// is no parent tracking the pointer, and a glyph that stays faint under the
/// cursor reads as decoration rather than as a button.
class _ClearButton extends StatefulWidget {
  const _ClearButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: 'Clear the filter',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(6),
            hoverColor: AppSurface.hoverFill,
            splashFactory: NoSplash.splashFactory,
            onHover: (value) => setState(() => _hovered = value),
            child: SizedBox(
              width: 20,
              height: 20,
              child: Icon(
                LucideIcons.x300,
                size: 13,
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

/// The flattened tree, drawn lazily — a big expanded folder builds only the
/// rows on screen.
class _Rows extends StatelessWidget {
  const _Rows({
    required this.rows,
    required this.filtered,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    required this.onAddToChat,
  });

  final List<WorkspaceRow> rows;
  final bool filtered;
  final String? selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<WorkspaceEntry> onOpen;
  final ValueChanged<String>? onAddToChat;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      // Says *why* there's nothing: the tree only holds folders that have been
      // opened, so "no match" here doesn't mean the file isn't in the project.
      return _Message(
        filtered
            ? 'No match in the folders you have opened. Open a folder to search '
                  'inside it.'
            : 'Nothing here.',
      );
    }
    final onAddToChat = this.onAddToChat;
    if (onAddToChat == null) return _list(null);
    return FileTreeContextMenu(
      onAddToChat: onAddToChat,
      builder: (context, onContextMenu) => _list(onContextMenu),
    );
  }

  Widget _list(
    void Function(WorkspaceEntry entry, Offset globalPosition)? onContextMenu,
  ) => ListView.builder(
    padding: const EdgeInsets.only(left: 4, right: 6, bottom: 8),
    itemCount: rows.length,
    itemBuilder: (context, i) => switch (rows[i]) {
      WorkspaceEntryRow(:final entry, :final depth, :final isExpanded) =>
        FileTreeEntryRow(
          entry: entry,
          depth: depth,
          isExpanded: isExpanded,
          isSelected: entry.path == selected,
          onTap: () => entry.isDirectory ? onToggle(entry.path) : onOpen(entry),
          onContextMenu: onContextMenu,
        ),
      WorkspaceStatusRow(:final depth, :final isError) => FileTreeStatusRow(
        depth: depth,
        isError: isError,
      ),
    },
  );
}

/// A quiet, centred sentence for the states with no rows to draw.
class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
