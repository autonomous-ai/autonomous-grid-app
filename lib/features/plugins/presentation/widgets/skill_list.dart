import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../agent/logic/hermes_skill_installer.dart';
import '../../logic/agent_skill.dart';
import '../../logic/skill_author.dart';
import 'extension_tile_surface.dart';
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

class _SkillRow extends ConsumerStatefulWidget {
  const _SkillRow({required this.skill});

  final AgentSkill skill;

  @override
  ConsumerState<_SkillRow> createState() => _SkillRowState();
}

class _SkillRowState extends ConsumerState<_SkillRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final skill = widget.skill;
    final confirmed = await _confirmDeleteSkill(context, skill.name);
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    var message = '${skill.name} deleted.';
    try {
      await ref.read(skillAuthorProvider).delete(skill.path);
    } on Object catch (error) {
      message = "Couldn't delete the skill: $error";
    }
    ref.invalidate(agentSkillsProvider);
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExtensionIconBadge(icon: Icons.auto_awesome_outlined),
          const SizedBox(width: 12),
          Expanded(child: _SkillInfo(skill: skill)),
          if (!skill.fromGrid) ...[
            const SizedBox(width: 8),
            _SkillActions(skill: skill, busy: _busy, onDelete: _delete),
          ],
        ],
      ),
    );
  }
}

/// The skill's name, its Hermes category, and one line of what it does.
class _SkillInfo extends StatelessWidget {
  const _SkillInfo({required this.skill});

  final AgentSkill skill;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    return Column(
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
              const ExtensionTag(label: 'From Grid'),
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
    );
  }
}

/// Edit (only the user's own skills) and delete (anything Grid doesn't manage).
/// A Grid skill has neither — this whole row is hidden for it, since "Reinstall
/// Grid's skills" is how those are managed.
class _SkillActions extends StatelessWidget {
  const _SkillActions({
    required this.skill,
    required this.busy,
    required this.onDelete,
  });

  final AgentSkill skill;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (skill.isMine)
          IconButton(
            tooltip: 'Edit',
            iconSize: 18,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.edit_outlined),
            onPressed: busy ? null : () => showEditSkillDialog(context, skill),
          ),
        IconButton(
          tooltip: 'Delete',
          iconSize: 18,
          color: AppPalette.textSecondary,
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: busy ? null : onDelete,
        ),
      ],
    );
  }
}

/// Removing a skill takes its folder with it, and the user may have written it,
/// so ask before doing something they can't undo.
Future<bool?> _confirmDeleteSkill(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this skill?'),
      content: Text(
        '"$name" will be removed from this computer and the assistant will '
        'stop using it. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}

/// No skills at all — offer the two things that fix it rather than a blank page.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No skills installed yet.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            children: [
              FilledButton.icon(
                onPressed: () => showNewSkillDialog(context),
                icon: const Icon(Icons.add_rounded, size: AppControl.iconSize),
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
          : const Icon(Icons.refresh_rounded, size: AppControl.iconSize),
      label: Text(_busy ? 'Installing…' : "Reinstall Grid's skills"),
    );
  }
}
