/// How the app looks: the settings this phone owns for itself.
///
/// Rows and segments rather than the Mac's three pictures of the app wearing
/// each theme and its typed px boxes. That screen has the room to show you the
/// answer and the keyboard to type a number into; here the app *is* the preview
/// — every one of these applies on the tap — and a number pad in front of the
/// thing being resized is the wrong control.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/appearance_prefs.dart';
import 'appearance_preview.dart';
import 'controls.dart';
import 'font_picker_sheet.dart';
import 'parts.dart';

/// Theme, text size and the faces the app is set in.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final look = ref.watch(appearanceProvider);
    final controller = ref.read(appearanceProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel(
          'Appearance',
          subtitle: 'System follows your phone’s own light/dark setting.',
        ),
        for (final mode in ThemeMode.values)
          _ThemeRow(
            mode: mode,
            selected: mode == look.themeMode,
            onTap: () => controller.apply(look.copyWith(themeMode: mode)),
          ),
        const SizedBox(height: 20),
        const SectionLabel(
          'Text',
          subtitle:
              'Code is sized on its own, so it can stay compact in a larger '
              'app. Your phone’s own text size still applies on top.',
        ),
        _SizeRow(
          title: 'App text',
          steps: kUiSizeSteps,
          current: look.uiSize,
          onPick: (size) => controller.apply(look.copyWith(uiSize: size)),
        ),
        const SizedBox(height: 12),
        _SizeRow(
          title: 'Code text',
          steps: kCodeSizeSteps,
          current: look.codeSize,
          onPick: (size) => controller.apply(look.copyWith(codeSize: size)),
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'App font',
          value: look.uiFamily ?? 'System',
          onTap: () => showFontPicker(
            context,
            code: false,
            current: look.uiFamily,
            onPick: (family) =>
                controller.apply(look.copyWith(uiFamily: family)),
          ),
        ),
        SettingRow(
          title: 'Code font',
          value: look.codeFamily ?? 'System Mono',
          onTap: () => showFontPicker(
            context,
            code: true,
            current: look.codeFamily,
            onPick: (family) =>
                controller.apply(look.copyWith(codeFamily: family)),
          ),
        ),
        const SizedBox(height: 12),
        const AppearancePreview(),
      ],
    );
  }
}

/// One theme, and whether it is the one on.
class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final color = selected ? AppPalette.accent : AppPalette.textFaint;
    return GridListRow(
      onTap: onTap,
      child: Row(
        children: [
          Icon(themeModeIcon(mode), size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              themeModeLabel(mode),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          // A tick, not a switch: these three are one choice, and three toggles
          // would say you could have two of them.
          if (selected)
            Icon(Icons.check_rounded, size: 18, color: AppPalette.accent),
        ],
      ),
    );
  }
}

/// A named size, picked from a row of steps.
class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.title,
    required this.steps,
    required this.current,
    required this.onPick,
  });

  final String title;
  final List<({String label, double size})> steps;
  final double current;
  final ValueChanged<double> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(title, style: Theme.of(context).textTheme.bodySmall),
        ),
        SegmentedChoice<double>(
          options: [
            for (final step in steps) (label: step.label, value: step.size),
          ],
          selected: current,
          onPick: onPick,
        ),
      ],
    );
  }
}
