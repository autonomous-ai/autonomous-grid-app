import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/skills/agent_skill_home.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_catalog.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../../agents/presentation/agent_mark.dart';
import '../../logic/skill_sharing.dart';
import '../../logic/skills_controller.dart';
import 'share_skill_button.dart';
import 'skill_detail_dialog.dart';
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
const double _kActionsColumn = 88;

/// How much of a skill's description a row shows before the ellipsis. Narrower
/// than the column it sits in, on purpose — see [_SkillInfo].
const double _kDescriptionWidth = 380;

/// The skills installed for the assistant — instructions it follows for one job
/// ("make an image on the grid", "write my weekly report").
///
/// A table rather than chapters: the store holds only what the app manages, so
/// the list is short, and the two things worth knowing about a row — when it
/// last changed and whose it is — are columns you can scan instead of tags
/// scattered through the names.
class SkillList extends StatelessWidget {
  const SkillList({
    super.key,
    required this.skills,
    required this.source,
    this.filtered = false,
  });

  final List<AgentSkill> skills;

  /// Which folder these came from — only used when there's nothing to show, so
  /// the page can say which folder is empty and offer what makes sense there.
  final SkillSource source;

  /// A search is narrowing the list, so an empty [skills] means "nothing
  /// matched" — not "nothing installed". Offering "Write a skill" there would
  /// answer a question the user didn't ask.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return filtered
          ? const EmptyState.noMatches(message: 'No skills match that search.')
          : _Empty(source: source);
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
            rowBuilder: (context, skill) =>
                _SkillRow(skill: skill, source: source),
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
  const _SkillRow({required this.skill, required this.source});

  final AgentSkill skill;
  final SkillSource source;

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
    // The whole row opens the skill — a skill is a folder of files, and the
    // row can only ever show its cover. The buttons on the right keep their own
    // taps: the innermost detector wins the arena, so Delete never opens the
    // viewer on its way to the confirmation.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => showSkillDetail(context, skill),
        child: ExtensionTileSurface(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ExtensionIconBadge(
                icon: Icons.auto_awesome_outlined,
                // The user's own skills carry the accent — the same signal the
                // plugin list gives an enabled plugin: "this one is
                // yours/live".
                active: skill.isMine,
              ),
              const SizedBox(width: 12),
              Expanded(child: _SkillInfo(skill: skill, source: widget.source)),
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
                child: _SkillActions(
                  skill: skill,
                  source: widget.source,
                  busy: _busy,
                  onDelete: _delete,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The skill's name, which other assistant also has it, and one line of what
/// it does.
class _SkillInfo extends ConsumerWidget {
  const _SkillInfo({required this.skill, required this.source});

  final AgentSkill skill;

  /// The tab this row is in — the assistant that has it — so the marks beside
  /// the name can name the *others*.
  final SkillSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                style: theme.textTheme.titleSmall,
              ),
            ),
            // The other assistants that also have it, by their own marks — a
            // logo is read at a glance where a word-tag would compete with the
            // name beside it. The tab's own agent is never marked: every row
            // here is theirs, so saying so on all of them says nothing.
            for (final agent in _alsoOn(ref, source))
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: '${agent.name} has it too',
                  child: AgentMark(tool: agent, size: 15),
                ),
              ),
          ],
        ),
        if (skill.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          // One short line. A skill card's description is written for the agent
          // to match against, so it often runs to a paragraph of trigger words
          // — left to fill the column it becomes the loudest thing on the row
          // and the names stop being scannable. Cut it well before the column
          // ends; the row opens to the whole card, and the tooltip has the
          // rest meanwhile.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kDescriptionWidth),
            child: Tooltip(
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
          ),
        ],
      ],
    );
  }

  /// The *other* assistants that also have this skill, by folder name.
  ///
  /// Read off their folders rather than a record of what the app copied: a
  /// skill can be in both places without the app having put it there, and the
  /// row should say what is true.
  List<AgentTool> _alsoOn(WidgetRef ref, SkillSource source) {
    final slug = skill.path.split('/').last;
    return [
      for (final agent in AgentTool.values)
        if (agent != source.agent)
          if (switch (ref.watch(agentSkillNamesProvider(agent))) {
            AsyncData(:final value) => value.contains(slug),
            _ => false,
          })
            agent,
    ];
  }
}

/// Edit, share and delete — on every row.
///
/// The tabs are the assistants' own folders now, so a row is a skill that
/// assistant really has, and all three verbs mean something for all of them.
/// Editing one the agent shipped is the user's call to make: the next agent
/// update may write over it, which is a reason to warn, not a reason to
/// withhold the button.
class _SkillActions extends StatelessWidget {
  const _SkillActions({
    required this.skill,
    required this.source,
    required this.busy,
    required this.onDelete,
  });

  final AgentSkill skill;
  final SkillSource source;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppIconButton(
          tooltip: 'Edit',
          icon: Icons.edit_outlined,
          onPressed: busy ? null : () => showEditSkillDialog(context, skill),
        ),
        const SizedBox(width: 2),
        ShareSkillButton(skill: skill, from: source, busy: busy),
        const SizedBox(width: 2),
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

/// No skills in this folder.
///
/// Both tabs are an assistant's own folder now, so the offer is the same in
/// each: write one, or put Grid's own back. What changes is the name of the
/// folder that is empty, which is the part the user can go and check.
class _Empty extends StatelessWidget {
  const _Empty({required this.source});

  final SkillSource source;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.auto_awesome_outlined,
      title: '${source.label} has no skills yet',
      message:
          'A skill teaches an assistant one job, in your own words. '
          '${source.label} reads them from ${_folder(source)} — write one and '
          "give it to ${source.label}, or put Grid's own skills back.",
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

  /// Named home-relative, the way the user would type it.
  static String _folder(SkillSource source) => switch (source) {
    SkillSource.store => '~/.grid/skills',
    SkillSource.hermes => '~/.hermes/skills',
    SkillSource.codex => '~/.codex/skills',
  };
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
