import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../chat/logic/workspace_browser.dart';
import '../../../projects/logic/agent_workspace.dart';
import '../../logic/files_browser.dart';
import '../../logic/files_filter.dart';
import 'file_type_icon.dart';

/// Left indent added per folder deep. Narrower than the file dialog's 16: this
/// column is a third of a panel, and four levels in at 16 leaves no room for a
/// name.
const double _indentStep = 12;

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
  });

  final String tabId;

  /// The project folder the tree is rooted at. It never reaches above this.
  final String root;

  /// A file was picked — the panel shows it.
  final ValueChanged<WorkspaceEntry> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(filesBrowserProvider(tabId));
    final entries = ref.watch(workdirEntriesProvider(root));

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
                  childrenOf: (path) => ref.watch(workdirEntriesProvider(path)),
                ),
                state.query,
              ),
              filtered: state.query.trim().isNotEmpty,
              selected: state.selected,
              onToggle: (path) => ref
                  .read(filesBrowserProvider(tabId).notifier)
                  .toggleFolder(path),
              onOpen: onOpen,
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: AppControl.heightSmall,
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
  });

  final List<WorkspaceRow> rows;
  final bool filtered;
  final String? selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<WorkspaceEntry> onOpen;

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
    return ListView.builder(
      padding: const EdgeInsets.only(left: 4, right: 6, bottom: 8),
      itemCount: rows.length,
      itemBuilder: (context, i) => switch (rows[i]) {
        WorkspaceEntryRow(:final entry, :final depth, :final isExpanded) =>
          _EntryRow(
            entry: entry,
            depth: depth,
            isExpanded: isExpanded,
            isSelected: entry.path == selected,
            onTap: () =>
                entry.isDirectory ? onToggle(entry.path) : onOpen(entry),
          ),
        WorkspaceStatusRow(:final depth, :final isError) => _StatusRow(
          depth: depth,
          isError: isError,
        ),
      },
    );
  }
}

/// One file or folder. A folder shows a chevron that turns as it opens; a file
/// shows as selected once it's the one on screen.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    required this.onTap,
  });

  final WorkspaceEntry entry;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final isDir = entry.isDirectory;
    return Material(
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
            left: 6 + depth * _indentStep,
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
  }
}

/// The line inside an expanded folder while its contents arrive, or after they
/// fail — indented to sit under that folder's children.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.depth, required this.isError});

  final int depth;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 6 + depth * _indentStep + 23,
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
