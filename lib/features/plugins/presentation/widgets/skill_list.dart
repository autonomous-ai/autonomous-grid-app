import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agent/logic/hermes_skill_installer.dart';
import '../../logic/agent_skill.dart';
import '../../logic/skill_author.dart';
import 'extension_tile_surface.dart';
import 'new_skill_dialog.dart';

/// The skills installed for the assistant — instructions it follows for one job
/// ("make an image on the grid", "write my weekly report"), grouped by the folder
/// Hermes files them under.
class SkillList extends StatelessWidget {
  const SkillList({super.key, required this.skills, this.filtered = false});

  final List<AgentSkill> skills;

  /// A search is narrowing the list, so an empty [skills] means "nothing
  /// matched" — not "nothing installed". Offering "Write a skill" there would
  /// answer a question the user didn't ask.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return filtered
          ? const EmptyState.noMatches(message: 'No skills match that search.')
          : const _Empty();
    }
    final items = _sectioned(skills);
    // Read the answer off the built list rather than re-deriving it: _sectioned
    // also falls back to flat when every skill shares one category, and a row in
    // that list still has to name its own — otherwise the category disappears
    // from the screen entirely.
    final headed = items.any((item) => item is _Header);
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      // See PluginList: extra air before a header; the lookahead is in range
      // because separators only fall between two items.
      separatorBuilder: (context, i) =>
          SizedBox(height: items[i + 1] is _Header ? 18 : 8),
      itemBuilder: (context, i) => switch (items[i]) {
        _Header(:final label, :final count) => ExtensionSectionHeader(
          label: label,
          count: count,
        ),
        _Row(:final skill) => _SkillRow(skill: skill, showCategory: !headed),
      },
    );
  }

  /// Grouped by the folder Hermes files each skill under, the user's own first.
  ///
  /// Hermes ships ~70 skills, so a flat alphabetical list mixes the two the user
  /// wrote in among seventy they didn't — and the category was already computed
  /// for exactly this, then thrown away by rendering flat.
  ///
  /// No sections while searching: chapters over a three-hit list are noise.
  List<_Item> _sectioned(List<AgentSkill> skills) {
    if (filtered) return [for (final s in skills) _Row(s)];

    final groups = <String, List<AgentSkill>>{};
    for (final skill in skills) {
      // A skill sitting loose at the top of the folder has no category; give it
      // a heading of its own rather than hiding it under someone else's.
      final key = skill.category.isEmpty ? 'Other' : skill.category;
      groups.putIfAbsent(key, () => []).add(skill);
    }
    if (groups.length < 2) return [for (final s in skills) _Row(s)];

    final names = groups.keys.toList()
      ..sort((a, b) {
        // The user's own skills lead — they're the ones they came here to find.
        if (a == kMySkillsCategory) return -1;
        if (b == kMySkillsCategory) return 1;
        return a.compareTo(b);
      });

    return [
      for (final name in names) ...[
        _Header(
          name == kMySkillsCategory ? 'My skills' : name,
          groups[name]!.length,
        ),
        for (final skill in groups[name]!) _Row(skill),
      ],
    ];
  }
}

/// One entry in the built list — a section header or a skill row.
sealed class _Item {
  const _Item();
}

class _Header extends _Item {
  const _Header(this.label, this.count);

  final String label;
  final int count;
}

class _Row extends _Item {
  const _Row(this.skill);

  final AgentSkill skill;
}

class _SkillRow extends ConsumerStatefulWidget {
  const _SkillRow({required this.skill, this.showCategory = false});

  final AgentSkill skill;

  /// See [_SkillInfo.showCategory] — true only in the flat (searching) list,
  /// where no header names the category.
  final bool showCategory;

  @override
  ConsumerState<_SkillRow> createState() => _SkillRowState();
}

class _SkillRowState extends ConsumerState<_SkillRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final skill = widget.skill;
    final confirmed = await _confirmDeleteSkill(context, skill.name);
    if (confirmed != true || !mounted) return;

    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    String? failure;
    try {
      await ref.read(skillAuthorProvider).delete(skill.path);
    } on Object catch (error) {
      failure = "Couldn't delete the skill: $error";
    }
    ref.invalidate(agentSkillsProvider);
    if (mounted) setState(() => _busy = false);
    toast?.show(
      failure != null
          ? ToastSpec(message: failure, severity: ToastSeverity.error)
          : ToastSpec(
              message: '${skill.name} deleted.',
              severity: ToastSeverity.success,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExtensionIconBadge(
            icon: Icons.auto_awesome_outlined,
            // The user's own skills carry the accent — the same signal the
            // plugin list gives an enabled plugin: "this one is yours/live".
            active: skill.isMine,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SkillInfo(skill: skill, showCategory: widget.showCategory),
          ),
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
  const _SkillInfo({required this.skill, required this.showCategory});

  final AgentSkill skill;

  /// False when a section header already names the category — repeating it on
  /// every row under its own heading is just noise beside the name.
  final bool showCategory;

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
                style: theme.textTheme.titleSmall?.copyWith(),
              ),
            ),
            if (showCategory && skill.category.isNotEmpty) ...[
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
              const ExtensionTag(label: 'From Grid', muted: true),
            ],
          ],
        ),
        if (skill.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          // One line, like the plugin rows: a skill card's description is
          // written for the agent to match against, so it often runs to a
          // paragraph of trigger words. The full text is the tooltip.
          Tooltip(
            message: skill.description,
            waitDuration: const Duration(milliseconds: 600),
            child: Text(
              skill.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
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
    return EmptyState(
      icon: Icons.auto_awesome_outlined,
      title: 'No skills installed yet',
      message:
          'A skill teaches the assistant one job, in your own words — write '
          "one, or put Grid's own skills back.",
      action: Wrap(
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
    String? failure;
    try {
      await ref.read(hermesSkillInstallerProvider).install();
      ref.invalidate(agentSkillsProvider);
    } on Object catch (error) {
      failure = "Couldn't install Grid's skills: $error";
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ToastScope.showResult(
      context,
      error: failure,
      success: "Grid's skills are up to date.",
    );
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _reinstall,
      icon: _busy
          ? const AppSpinner()
          : const Icon(Icons.refresh_rounded, size: AppControl.iconSize),
      label: Text(_busy ? 'Installing…' : "Reinstall Grid's skills"),
    );
  }
}
