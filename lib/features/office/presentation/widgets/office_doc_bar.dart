import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_segmented.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';
import '../../logic/office_view_mode.dart';
import '../discard_changes_dialog.dart';

/// The strip above the page: which document this is, whether it is saved, and
/// the two things you can do to it.
///
/// Two, and that is the whole point of this first version — open a document and
/// write it back. There is no ribbon to hide behind, so the bar says plainly what
/// the app can do.
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
                    if (open != null && !tight) ...[
                      _ViewSwitch(hasViewer: open.bytes != null),
                      const SizedBox(width: 12),
                    ],
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
                    // Folded to one glyph rather than dropped: the switch is how
                    // you get to the editor at all, so it is the last thing a
                    // narrow bar may lose.
                    if (open != null && tight) ...[
                      _ViewSwitchButton(hasViewer: open.bytes != null),
                      const SizedBox(width: 4),
                    ],
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

/// Read or Edit — the two ways to have the open document on screen.
///
/// Both words are on it because they are different capabilities, not different
/// skins: Read is the document as it really is and cannot be typed in, Edit is
/// where the caret goes. Collapses to the one word that is true when the file's
/// bytes aren't there for the viewer, with the reason in a tooltip rather than a
/// switch that silently does nothing.
class _ViewSwitch extends ConsumerWidget {
  const _ViewSwitch({required this.hasViewer});

  final bool hasViewer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const modes = OfficeViewMode.values;
    final mode = ref.watch(officeViewModeProvider);
    if (!hasViewer) {
      return Tooltip(
        message:
            "Grid couldn't hand this document to the viewer, so only the "
            'editable view is available.',
        child: Text(
          OfficeViewMode.edit.label,
          style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
        ),
      );
    }
    return AppSegmented(
      segments: [for (final m in modes) SegmentSpec(label: m.label)],
      selected: modes.indexOf(mode),
      onChanged: (index) =>
          ref.read(officeViewModeProvider.notifier).select(modes[index]),
    );
  }
}

/// The switch folded to one button, for a bar with no room for two words.
class _ViewSwitchButton extends ConsumerWidget {
  const _ViewSwitchButton({required this.hasViewer});

  final bool hasViewer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasViewer) return const SizedBox.shrink();
    final formatted = ref.watch(officeViewModeProvider) == OfficeViewMode.read;
    return AppIconButton(
      icon: formatted ? LucideIcons.pencil300 : LucideIcons.layoutPanelTop300,
      size: 16,
      // Names what the press will do, not what is on screen — the one thing a
      // single-button toggle has to get right.
      tooltip: formatted ? 'Edit the text' : 'Show the formatting',
      onPressed: () => ref.read(officeViewModeProvider.notifier).toggle(),
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
