/// Choosing a font face.
///
/// A sheet rather than a dropdown: the list is as long as the phone's font book
/// and a dropdown that tall is a scroll inside a popup. It asks one question,
/// which is what a sheet is for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_fonts.dart';
import 'parts.dart';

/// Offers the faces this phone has for [code] or for the UI, and hands back the
/// chosen family — or null for the system's own. Returns nothing when dismissed.
Future<void> showFontPicker(
  BuildContext context, {
  required bool code,
  required String? current,
  required ValueChanged<String?> onPick,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: AppPalette.panelBg,
  builder: (_) =>
      _FontPickerSheet(code: code, current: current, onPick: onPick),
);

class _FontPickerSheet extends ConsumerWidget {
  const _FontPickerSheet({
    required this.code,
    required this.current,
    required this.onPick,
  });

  final bool code;
  final String? current;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final installed =
        ref.watch(installedFontFamiliesProvider).asData?.value ??
        InstalledFonts.none;
    final options = buildFontOptions(
      curated: code ? kPhoneCodeFonts : kPhoneUiFonts,
      installed: installed.forCode(code),
    );
    return SafeArea(
      child: ConstrainedBox(
        // Half the screen at most, so the sheet never covers the thing it is
        // changing — the preview behind it is how you judge the answer.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          shrinkWrap: true,
          children: [
            SectionLabel(code ? 'Code font' : 'UI font'),
            for (final choice in options)
              // A face this phone doesn't have is not offered. Showing it
              // greyed would say the app supports it; showing it live would
              // render something else entirely under its name.
              if (choice.detail != 'Not installed' || choice.family == current)
                _FaceRow(
                  choice: choice,
                  code: code,
                  selected: choice.family == current,
                  onTap: () {
                    onPick(choice.family);
                    Navigator.of(context).pop();
                  },
                ),
          ],
        ),
      ),
    );
  }
}

/// One face, set in itself — the only honest way to show a font.
class _FaceRow extends StatelessWidget {
  const _FaceRow({
    required this.choice,
    required this.code,
    required this.selected,
    required this.onTap,
  });

  final FontChoice choice;
  final bool code;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridListRow(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  choice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    // Null family falls back to the app's own stack, which is
                    // exactly what this row means by "System".
                    fontFamily: choice.family ?? (code ? AppFont.mono : null),
                    fontFamilyFallback: choice.family != null
                        ? null
                        : (code ? AppFont.monoFallback : null),
                  ),
                ),
                RowDetail([choice.detail ?? '']),
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 18, color: AppPalette.accent),
        ],
      ),
    );
  }
}
