import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../logic/skill_files.dart';
import 'skill_folder_view.dart';

/// Opens an installed skill: what it says it does, and every file in its
/// folder.
///
/// A skill is a folder, not a row — the card is only its cover page, and the
/// scripts underneath are what it actually runs. Read-only wherever it came
/// from: this is for understanding a skill, not for editing one.
Future<void> showSkillDetail(BuildContext context, AgentSkill skill) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SkillDetailDialog(skill: skill),
    );

class _SkillDetailDialog extends StatelessWidget {
  const _SkillDetailDialog({required this.skill});

  final AgentSkill skill;

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 20),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  skill.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppIconButton(
                tooltip: 'Close',
                icon: Icons.close_rounded,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'by ${skill.owner.label}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          if (skill.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            // The card's own description in full — the row could only show a
            // sentence of it, and this is the line the agent matches on.
            Text(
              skill.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: math.min(760, size.width * 0.86),
        height: math.min(460, size.height * 0.66),
        child: SkillFolderView(folder: diskSkillFolder(skill.path)),
      ),
      actions: [
        // The folder itself, selectable — the answer to "where is this?" and
        // the only way to act on a skill the app won't edit for you.
        Expanded(
          child: CodeTextScope(
            child: SelectableText(
              skill.path,
              maxLines: 1,
              style: AppFont.codeStyle(
                color: AppPalette.textFaint,
                scale: 0.92,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
