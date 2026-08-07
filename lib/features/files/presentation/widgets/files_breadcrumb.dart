import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';

/// Where the open file sits, from the project's folder down — `grid › lib ›
/// main.dart`.
///
/// The last crumb is the file and carries the ink; the folders above it stay
/// quiet. They aren't links: the tree beside them is how you move, and two ways
/// to do the same thing in one panel is one more than the panel is wide enough
/// to explain.
class FilesBreadcrumb extends StatelessWidget {
  const FilesBreadcrumb({super.key, required this.crumbs});

  /// Root folder first, file last. Never empty — the root's own name stands
  /// alone before anything is picked, so the bar always says which folder this
  /// is.
  final List<String> crumbs;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Icon(LucideIcons.folder300, size: 14, color: AppPalette.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // A deep path scrolls rather than ellipsing, and starts at its end:
            // the file's own name is the part worth reading, and the part an
            // ellipsis would eat.
            reverse: true,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        LucideIcons.chevronRight300,
                        size: 13,
                        color: AppPalette.textFaint,
                      ),
                    ),
                  Text(
                    crumbs[i],
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: i == crumbs.length - 1
                          ? AppFont.medium
                          : FontWeight.w400,
                      color: i == crumbs.length - 1
                          ? AppPalette.textPrimary
                          : AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
