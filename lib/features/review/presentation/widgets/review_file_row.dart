import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_file.dart';
import '../../logic/review_selection.dart';
import 'review_mark.dart';

/// One changed file in the list: what happened to it, how much of it changed,
/// and whether it's going into the next commit.
///
/// The whole row opens the file's diff; only the tick changes what Git holds.
class ReviewFileRow extends ConsumerWidget {
  const ReviewFileRow({
    super.key,
    required this.file,
    required this.folder,
    required this.stageable,
  });

  final ReviewFile file;

  /// The folder being reviewed — the key for both the selection and the
  /// controller that stages.
  final String folder;

  /// Whether staging is on offer at all. A branch comparison shows work that is
  /// already committed: a tick there would be a control that does nothing.
  final bool stageable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ExtensionTileSurface(
      onTap: () =>
          ref.read(reviewSelectionProvider(folder).notifier).open(file.path),
      child: Row(
        children: [
          ReviewMark(kind: file.kind),
          const SizedBox(width: 10),
          Expanded(child: _Name(file: file)),
          const SizedBox(width: 8),
          ChangeCount(
            added: file.added,
            removed: file.removed,
            binary: file.binary,
          ),
          if (stageable) ...[
            const SizedBox(width: 4),
            _StageToggle(file: file, folder: folder),
          ],
        ],
      ),
    );
  }
}

/// The file's name, with where it moved from underneath when it moved.
class _Name extends StatelessWidget {
  const _Name({required this.file});

  final ReviewFile file;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final oldPath = file.oldPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
            // A deleted file's name is struck through: the row is about a file
            // that isn't there any more, and the mark alone is easy to miss.
            decoration: file.kind == ReviewFileKind.deleted
                ? TextDecoration.lineThrough
                : null,
          ),
        ),
        if (oldPath != null)
          Text(
            'was $oldPath',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: AppPalette.textSecondary),
          ),
      ],
    );
  }
}

/// Include this file in the next commit, or leave it out.
class _StageToggle extends ConsumerWidget {
  const _StageToggle({required this.file, required this.folder});

  final ReviewFile file;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // A half-merged file can't be staged from here: ticking it would record a
    // commit with conflict markers in it, and resolving the merge is not
    // something this surface can honestly offer.
    if (file.kind == ReviewFileKind.conflicted) {
      return Tooltip(
        message: 'Finish the merge before committing this file',
        child: Icon(
          LucideIcons.triangleAlert,
          size: 15,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
    return AppIconButton(
      icon: file.staged ? LucideIcons.circleCheck : LucideIcons.circle,
      size: 15,
      color: file.staged ? AppPalette.accentOnSurface : AppPalette.textFaint,
      tooltip: file.staged
          ? 'In the next commit — click to leave it out'
          : 'Include in the next commit',
      onPressed: () => _toggle(context, ref),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(reviewProvider(folder).notifier);
    final failure = file.staged
        ? await controller.unstage(file)
        : await controller.stage(file);
    if (failure == null || !context.mounted) return;
    ToastScope.show(
      context,
      ToastSpec(message: failure, severity: ToastSeverity.error),
    );
  }
}
