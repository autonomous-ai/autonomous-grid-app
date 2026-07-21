import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';

/// A titled, numbered walkthrough to finish setup — the app's own [steps] in
/// plain language. Rendered as an accent-tinted card with numbered badges so
/// the manual steps read as a distinct "do this" block instead of blending
/// into the surrounding copy (users were skipping past it).
class SetupSteps extends StatelessWidget {
  const SetupSteps({super.key, required this.title, required this.steps});

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The focal "do this now" block on the page, so it takes the hero surface —
    // its accent wash + rim is the system's way of saying what the old
    // hand-rolled 6%-tint-plus-border was imitating, and it drops the border.
    return GlassCard(
      style: GlassCardStyle.hero,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // accentOnSurface, not accent: on the dark hero wash the flat
              // #2F5BEA measures 3.21:1 — this lifts the mark to 5.73:1.
              Icon(
                Icons.tune_rounded,
                size: 16,
                color: AppPalette.accentOnSurface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _StepRow(number: i + 1, text: steps[i]),
            ),
        ],
      ),
    );
  }
}

/// One numbered step: an accent badge with its ordinal beside the instruction.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppPalette.accent.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          // The ordinal on its own 16% wash measured 2.95:1 in dark — under the
          // 3.0 WCAG 1.4.11 floor. accentOnSurface takes it to 5.28:1.
          child: Text(
            '$number',
            style: TextStyle(
              color: AppPalette.accentOnSurface,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              text,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A subtle link to the app's official site for deeper setup docs.
class DocsLink extends StatelessWidget {
  const DocsLink({super.key, required this.appName, required this.onOpen});

  final String appName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Accent *text on a surface*, not a fill — so it takes accentOnSurface.
    // Flat accent measured 3.34:1 on the dark page; this reads 5.97:1.
    final tint = AppPalette.accentOnSurface;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(AppControl.radius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$appName docs',
              style: TextStyle(
                color: tint,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.open_in_new_rounded, size: 13, color: tint),
          ],
        ),
      ),
    );
  }
}
