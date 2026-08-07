import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../projects/logic/agent_workspace.dart';
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
  }
}

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
