import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/pill_choice.dart';
import '../../logic/skill_sharing.dart';
import '../../logic/skills_controller.dart';

/// Which assistant gets a copy of the skill being added — one of them, or both.
///
/// Every way in asks the same question in the same place — writing one,
/// uploading a folder, taking one from the catalog — and they share one answer
/// ([skillTargetProvider]), so a user who picked Codex once isn't asked again
/// on the next screen. The skill lands in the store either way; this only
/// decides who else gets a copy.
class SkillTargetPicker extends ConsumerWidget {
  const SkillTargetPicker({
    super.key,
    this.label = 'Which assistant gets it?',
    this.inline = false,
  });

  final String label;

  /// Label and pills on one line — for a screen that has the width but not the
  /// height to spare.
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final chosen = ref.watch(skillTargetProvider);
    final caption = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: AppPalette.textSecondary,
      ),
    );
    final pills = [
      for (final target in ShareTarget.values)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PillChoice(
            label: Text(target.chip),
            selected: target == chosen,
            onTap: () => ref.read(skillTargetProvider.notifier).select(target),
          ),
        ),
    ];

    if (inline) {
      return Row(children: [caption, const SizedBox(width: 12), ...pills]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        caption,
        const SizedBox(height: 8),
        Row(children: pills),
      ],
    );
  }
}
