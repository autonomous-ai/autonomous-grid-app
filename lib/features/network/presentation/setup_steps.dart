import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        color: AppPalette.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.accent.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                size: 16,
                color: AppPalette.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
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
          child: Text(
            '$number',
            style: const TextStyle(
              color: AppPalette.accent,
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
              style: const TextStyle(
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
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$appName docs',
              style: const TextStyle(
                color: AppPalette.accent,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(
              Icons.open_in_new_rounded,
              size: 13,
              color: AppPalette.accent,
            ),
          ],
        ),
      ),
    );
  }
}
