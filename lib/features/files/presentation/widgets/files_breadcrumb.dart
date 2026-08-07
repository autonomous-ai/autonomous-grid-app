import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import 'file_type_icon.dart';

/// Where the open file sits, from the project's folder down — `grid › lib ›
/// main.dart`.
///
/// The last crumb is the file and carries the ink, with its type's icon in front
/// of it so the bar says *what* is open as well as where; the folders above it
/// stay quiet. They aren't links: the tree beside them is how you move, and two
/// ways to do the same thing in one panel is one more than the panel is wide
/// enough to explain.
class FilesBreadcrumb extends StatelessWidget {
  const FilesBreadcrumb({super.key, required this.crumbs, this.filePath});

  /// Root folder first, file last. Never empty — the root's own name stands
  /// alone before anything is picked, so the bar always says which folder this
  /// is.
  final List<String> crumbs;

  /// The open file, when there is one. Only its type is read from this — the
  /// name already came through [crumbs] — and it is null both when nothing is
  /// picked and when what is picked turns out to live outside the root.
  final String? filePath;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final last = crumbs.length - 1;
    final file = crumbs.length > 1 ? filePath : null;
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
                if (i == last && file != null) ...[
                  FileTypeIcon(path: file, size: 13),
                  const SizedBox(width: 5),
                ] else if (i == 0 && file == null) ...[
                  Icon(
                    LucideIcons.folder300,
                    size: 13,
                    color: AppPalette.textSecondary,
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  crumbs[i],
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: i == last ? AppFont.medium : FontWeight.w400,
                    color: i == last
                        ? AppPalette.textPrimary
                        : AppPalette.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
