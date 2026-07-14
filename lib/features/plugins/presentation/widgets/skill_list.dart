import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../agent/logic/hermes_skill_installer.dart';
import '../../logic/agent_skill.dart';
import 'new_skill_dialog.dart';

/// The skills installed for the assistant — instructions it follows for one job
/// ("make an image on the grid", "write my weekly report"), grouped by the folder
/// Hermes files them under.
class SkillList extends StatelessWidget {
  const SkillList({super.key, required this.skills});

  final List<AgentSkill> skills;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) return const _Empty();
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: skills.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _SkillRow(skill: skills[i]),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({required this.skill});

  final AgentSkill skill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.auto_awesome_outlined, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        skill.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (skill.category.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        skill.category,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textFaint,
                        ),
                      ),
                    ],
                    if (skill.fromGrid) ...[
                      const SizedBox(width: 8),
                      const _Tag(label: 'From Grid'),
                    ],
                  ],
                ),
                if (skill.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    skill.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppCard.accentStrong,
        ),
      ),
    );
  }
}

/// No skills at all — offer the two things that fix it rather than a blank page.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No skills installed yet.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            children: [
              FilledButton.icon(
                onPressed: () => showNewSkillDialog(context),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Write a skill'),
              ),
              const ReinstallGridSkillsButton(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Rewrites the skills Grid ships (image generation on your grid) and re-reads
/// the folder. Idempotent — also the fix for a skill deleted by mistake.
class ReinstallGridSkillsButton extends ConsumerStatefulWidget {
  const ReinstallGridSkillsButton({super.key});

  @override
  ConsumerState<ReinstallGridSkillsButton> createState() =>
      _ReinstallGridSkillsButtonState();
}

class _ReinstallGridSkillsButtonState
    extends ConsumerState<ReinstallGridSkillsButton> {
  bool _busy = false;

  Future<void> _reinstall() async {
    setState(() => _busy = true);
    var message = "Grid's skills are up to date.";
    try {
      await ref.read(hermesSkillInstallerProvider).install();
      ref.invalidate(agentSkillsProvider);
    } on Object catch (error) {
      message = "Couldn't install Grid's skills: $error";
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _reinstall,
      icon: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded, size: 16),
      label: Text(_busy ? 'Installing…' : "Reinstall Grid's skills"),
    );
  }
}
