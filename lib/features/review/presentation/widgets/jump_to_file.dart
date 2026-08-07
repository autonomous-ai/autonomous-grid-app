import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/review_file.dart';
import '../../logic/review_selection.dart';
import '../../logic/review_snapshot.dart';
import '../../logic/review_tree.dart';
import 'menu_row.dart';
import 'review_mark.dart';
import 'toolbar_popover.dart';

/// Type a few letters, open that file's diff.
///
/// The list beside the diff already lists everything, so this is not a second
/// way to browse — it is the way *not* to browse: on a branch with forty
/// changed files, finding one by scrolling a column 200px wide is the slowest
/// part of reading it.
class JumpToFile extends ConsumerWidget {
  const JumpToFile({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;

  /// The folder being reviewed — whose selection a pick moves.
  final String folder;

  /// Wide enough for a path a few folders deep before it ellipsizes.
  static const double width = 320;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ToolbarPopover(
      width: width,
      panel: (context, close) => _Panel(
        files: snapshot.files,
        onPick: (file) {
          ref.read(reviewSelectionProvider(folder).notifier).open(file.path);
          close();
        },
      ),
      trigger: (context, open, toggle) => AppIconButton(
        icon: LucideIcons.fileSearch2300,
        size: 15,
        tooltip: 'Jump to a changed file',
        onPressed: toggle,
      ),
    );
  }
}

/// The field and what it narrows to.
class _Panel extends StatefulWidget {
  const _Panel({required this.files, required this.onPick});

  final List<ReviewFile> files;
  final ValueChanged<ReviewFile> onPick;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The same filter the list beside the diff uses, so the two answer a typed
    // word the same way.
    final shown = filterFiles(widget.files, _query.text);

    return CallbackShortcuts(
      bindings: {
        // Enter takes the top match — the whole point of typing three letters
        // rather than reaching for the list.
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (shown.isNotEmpty) widget.onPick(shown.first);
        },
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 6, 15, 8),
            child: Row(
              children: [
                Icon(LucideIcons.search, size: 14, color: AppPalette.textFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppPalette.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Jump to file',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: AppPalette.textFaint,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const MenuDivider(),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 8, 15, 10),
              child: Text(
                'No changed file matches that.',
                style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
              ),
            )
          else
            // Capped so a branch with three hundred changed files doesn't build
            // three hundred rows into a panel that shows six — what is cut is
            // reachable by typing one more letter.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: shown.length,
                itemBuilder: (context, i) => MenuRow(
                  label: shown[i].name,
                  detail: shown[i].folder.isEmpty ? null : shown[i].folder,
                  width: JumpToFile.width,
                  trailing: ChangeCount(
                    added: shown[i].added,
                    removed: shown[i].removed,
                    binary: shown[i].binary,
                  ),
                  onTap: () => widget.onPick(shown[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
