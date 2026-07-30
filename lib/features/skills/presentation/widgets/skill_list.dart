import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../logic/skills_controller.dart';
import '../../../../shared/widgets/extension_list.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import 'new_skill_dialog.dart';

/// The width of each trailing column, so the header and every row line up.
///
/// Fixed rather than flexed: the whole point of a column is that the eye can
/// run down it, and a width that changed with its contents would put "You"
/// under a date on the row above.
const double _kUpdatedColumn = 104;
const double _kAuthorColumn = 76;
const double _kActionsColumn = 60;

/// The skills installed for the assistant — instructions it follows for one job
/// ("make an image on the grid", "write my weekly report").
///
/// A table rather than chapters: the store holds only what the app manages, so
/// the list is short, and the two things worth knowing about a row — when it
/// last changed and whose it is — are columns you can scan instead of tags
/// scattered through the names.
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
    // The scanner already orders them — the user's own first, then by when they
    // last changed — so the list draws what it's given.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ColumnHeader(),
        Expanded(
          child: ExtensionList(
            sections: [ExtensionSection(label: '', items: skills)],
            rowBuilder: (context, skill) => _SkillRow(skill: skill),
          ),
        ),
      ],
    );
  }
}

/// Names the columns once, over the list.
///
/// Indented to where a row's name starts (the icon well plus its gap) so the
/// label sits over the thing it names rather than over the icons.
class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
      color: AppPalette.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(57, 0, 14, 8),
      child: Row(
        children: [
          Expanded(child: Text('SKILL', style: style)),
          SizedBox(
            width: _kUpdatedColumn,
            child: Text('LAST UPDATED', style: style),
          ),
          SizedBox(width: _kAuthorColumn, child: Text('AUTHOR', style: style)),
          const SizedBox(width: _kActionsColumn),
        ],
      ),
    );
  }
}

/// `7/28/26` — the short date the Last updated column shows.
///
/// Hand-rolled: the app carries no date-formatting package, and a skill's date
/// only ever needs this one shape. Local time, because "when did I last touch
/// this" is a question about the user's day, not UTC's.
String formatSkillDate(DateTime when) {
  final local = when.toLocal();
  final year = (local.year % 100).toString().padLeft(2, '0');
  return '${local.month}/${local.day}/$year';
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

    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final failure = await ref.read(skillsProvider.notifier).delete(skill);
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
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final skill = widget.skill;
    final theme = Theme.of(context);
    final column = theme.textTheme.bodySmall?.copyWith(
      color: AppPalette.textSecondary,
    );
    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExtensionIconBadge(
            icon: Icons.auto_awesome_outlined,
            // The user's own skills carry the accent — the same signal the
            // plugin list gives an enabled plugin: "this one is yours/live".
            active: skill.isMine,
          ),
          const SizedBox(width: 12),
          Expanded(child: _SkillInfo(skill: skill)),
          SizedBox(
            width: _kUpdatedColumn,
            child: Text(formatSkillDate(skill.updatedAt), style: column),
          ),
          SizedBox(
            width: _kAuthorColumn,
            child: Text(
              skill.owner.label,
              overflow: TextOverflow.ellipsis,
              style: column,
            ),
          ),
          SizedBox(
            width: _kActionsColumn,
            child: _SkillActions(skill: skill, busy: _busy, onDelete: _delete),
          ),
        ],
      ),
    );
  }
}

/// The skill's name and one line of what it does.
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
        Text(
          skill.name,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
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

/// Edit and delete, offered only on the user's own skills.
///
/// A public skill has neither: it's rewritten by the next install, so an edit
/// would be undone and a delete would come back. "Reinstall Grid's skills" is
/// how those are managed. The column still takes its width on those rows, so
/// the ones above and below it stay in line.
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
    if (!skill.isMine) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppIconButton(
          tooltip: 'Edit',
          icon: Icons.edit_outlined,
          onPressed: busy ? null : () => showEditSkillDialog(context, skill),
        ),
        const SizedBox(width: 4),
        AppIconButton(
          tooltip: 'Delete',
          icon: Icons.delete_outline_rounded,
          destructive: true,
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
    final failure = await ref
        .read(skillsProvider.notifier)
        .reinstallGridSkills();
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
