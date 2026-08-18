import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';
import '../discard_changes_dialog.dart';

/// The strip above the page: which document this is, whether it is saved, and
/// what you can do to it — start a blank one, open another, write this one back.
///
/// No ribbon, because nothing here formats text. A bar that shows only what the
/// app can actually do is the honest shape for that.
class OfficeDocBar extends ConsumerWidget {
  const OfficeDocBar({super.key, required this.doc});

  /// The document on screen, or null while there is none — the bar keeps its
  /// Open button either way, since that is how the *next* document arrives.
  final OfficeDocOpen? doc;

  static const height = 44.0;

  /// Below this the bar trades its words for marks.
  ///
  /// It has to: the chat beside the page holds a hard floor (its composer
  /// overflows below it), so on the app's smallest window this bar gets about
  /// 150px and every label in it is optional next to not striping.
  static const _tightWidth = 300.0;

  /// Open a document, asking first when that would leave unsaved edits behind.
  ///
  /// The ask lives here rather than in the controller because it needs a
  /// [BuildContext], and the controller must stay callable without one.
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    OfficeDocOpen? open,
  ) async {
    if (open != null && open.dirty) {
      if (!await confirmDiscardChanges(context, open.name)) return;
    }
    await ref.read(officeDocProvider.notifier).pickAndOpen();
  }

  /// Start an empty document — asking first for the same reason [_open] does,
  /// since it also replaces what is on screen.
  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    OfficeDocOpen? open,
  ) async {
    if (open != null && open.dirty) {
      if (!await confirmDiscardChanges(context, open.name)) return;
    }
    await ref.read(officeDocProvider.notifier).createBlank();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final open = doc;
    final saving = open?.save is OfficeSaveRunning;
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tight = constraints.maxWidth < _tightWidth;
                return Row(
                  children: [
                    Icon(
                      LucideIcons.fileText300,
                      size: 15,
                      color: AppPalette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        open?.name ?? 'Docs',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 13.5,
                          fontWeight: AppFont.medium,
                        ),
                      ),
                    ),
                    if (open != null && open.dirty && !saving)
                      _NotSavedMark(tight: tight),
                    // A new document without going back to an empty screen
                    // first. Glyph-only even when there is room: it is the third
                    // action in a bar whose first two are the ones people came
                    // for.
                    if (!tight) ...[
                      AppIconButton(
                        icon: LucideIcons.filePlus300,
                        size: 16,
                        tooltip: 'New blank document',
                        onPressed: () => _create(context, ref, open),
                      ),
                      const SizedBox(width: 2),
                    ],
                    _OpenButton(
                      tight: tight,
                      hasDocument: open != null,
                      onPressed: () => _open(context, ref, open),
                    ),
                    if (open != null) ...[
                      const SizedBox(width: 8),
                      _SaveButton(
                        // Nothing to write, nothing to press — and a Save that
                        // stays live on an unchanged file teaches the user to
                        // click it out of doubt.
                        onPressed: open.dirty && !saving
                            ? () => ref.read(officeDocProvider.notifier).save()
                            : null,
                        saving: saving,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),
      ],
    );
  }
}

/// "There are edits here that the file doesn't have."
///
/// A word where there is room for one, because that sentence is worth reading
/// without hovering anything. Squeezed, it falls back to a dot in the app's
/// warning colour with the words in its tooltip — still visible, still true.
class _NotSavedMark extends StatelessWidget {
  const _NotSavedMark({required this.tight});

  final bool tight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: tight
        ? Tooltip(
            message: 'Not saved',
            child: StatusDot(color: AppPalette.warn, size: 6),
          )
        : Text(
            'Not saved',
            style: TextStyle(color: AppPalette.textFaint, fontSize: 12),
          ),
  );
}

/// The way the next document arrives — a labelled button, or its glyph alone
/// when the bar has no width for the label.
class _OpenButton extends StatelessWidget {
  const _OpenButton({
    required this.tight,
    required this.hasDocument,
    required this.onPressed,
  });

  final bool tight;
  final bool hasDocument;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = hasDocument ? 'Open another' : 'Open document';
    if (!tight) return TextButton(onPressed: onPressed, child: Text(label));
    return AppIconButton(
      icon: LucideIcons.folderOpen300,
      size: 16,
      // The full sentence, since the glyph is carrying the whole meaning here.
      tooltip: hasDocument ? 'Open another document' : 'Open document',
      onPressed: onPressed,
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onPressed, required this.saving});

  final VoidCallback? onPressed;
  final bool saving;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    child: saving
        ? const AppSpinner.onAccent(size: SpinnerSize.small)
        : const Text('Save'),
  );
}
