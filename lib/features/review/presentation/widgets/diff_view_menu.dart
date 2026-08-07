import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_file.dart';
import '../../logic/review_snapshot.dart';
import '../../logic/review_view_prefs.dart';
import 'menu_row.dart';

/// The "…" menu: how the diff is drawn, and the one thing you can take away
/// from it.
///
/// A menu rather than five more glyphs in the toolbar: these are settings a
/// user changes once and forgets, and a row of icons nobody can name is what a
/// toolbar becomes when every preference is given one.
class DiffViewMenu extends ConsumerWidget {
  const DiffViewMenu({
    super.key,
    required this.snapshot,
    required this.folder,
    this.file,
  });

  final ReviewSnapshot snapshot;
  final String folder;

  /// The file on screen, when one is — what "copy this diff" copies.
  final ReviewFile? file;

  static const double width = 268;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final prefs = ref.watch(diffViewPrefsProvider);
    final controls = ref.read(diffViewPrefsProvider.notifier);
    final open = file;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: appMenuStyle(),
      menuChildren: [
        MenuRow(
          label: prefs.wrap ? 'Stop wrapping long lines' : 'Wrap long lines',
          icon: LucideIcons.wrapText,
          width: width,
          onTap: controls.toggleWrap,
        ),
        MenuRow(
          label: prefs.ignoreWhitespace
              ? 'Show whitespace changes'
              : 'Hide whitespace changes',
          detail: prefs.ignoreWhitespace
              ? 'Lines that differ only in spacing are hidden'
              : 'A re-indented file reads as rewritten without this',
          icon: LucideIcons.pilcrow,
          width: width,
          onTap: controls.toggleWhitespace,
        ),
        MenuRow(
          label: prefs.collapsed
              ? 'Expand all sections'
              : 'Collapse all sections',
          icon: prefs.collapsed
              ? LucideIcons.unfoldVertical
              : LucideIcons.foldVertical,
          width: width,
          onTap: controls.toggleCollapsed,
        ),
        const MenuDivider(),
        MenuRow(
          label: 'Copy this file’s diff',
          detail: open == null ? 'Open a file first' : null,
          icon: LucideIcons.clipboard,
          width: width,
          enabled: open != null,
          onTap: () => _copy(context, ref, open!),
        ),
      ],
      builder: (context, controller, _) => AppIconButton(
        icon: LucideIcons.ellipsis,
        size: 15,
        tooltip: 'How this diff is shown',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// The patch as Git prints it — what `git apply` takes, and what a bug report
  /// or a message to a teammate wants.
  ///
  /// Read again rather than lifted off the pane: the pane holds it parsed into
  /// rows, and stitching those back into a patch would produce something that
  /// *looks* like one until someone tries to apply it.
  Future<void> _copy(BuildContext context, WidgetRef ref, ReviewFile on) async {
    final prefs = ref.read(diffViewPrefsProvider);
    final raw = await ref
        .read(reviewActionsProvider)
        .patch(
          root: snapshot.root,
          scope: snapshot.scope,
          file: on,
          ignoreWhitespace: prefs.ignoreWhitespace,
        );
    if (!context.mounted) return;
    if (raw == null || raw.trim().isEmpty) {
      ToastScope.show(
        context,
        const ToastSpec(
          message: "Git wouldn't print that file's diff.",
          severity: ToastSeverity.error,
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: raw));
    if (!context.mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: 'Copied the diff for ${on.name}.',
        severity: ToastSeverity.success,
      ),
    );
  }
}
