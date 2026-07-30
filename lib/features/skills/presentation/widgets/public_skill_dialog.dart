import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/extension_toolbar.dart';
import '../../../../shared/widgets/pill_choice.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/skills/agent_skill_home.dart';
import '../../logic/public_skill_catalog.dart';
import '../../logic/skill_files.dart';
import '../../logic/skill_sharing.dart';
import '../../logic/skills_controller.dart';
import 'skill_folder_view.dart';
import 'skill_target_picker.dart';

/// The catalog of skills the app ships with: browse them, read one, install it.
///
/// A gallery rather than the list the screen itself uses, because the questions
/// are different ones — what is this, who wrote it, have I got it already — and
/// then a reading view, because "install this and find out" is a bad deal when
/// the thing being installed runs scripts.
Future<void> showPublicSkillDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _PublicSkillDialog(),
);

/// Which of the catalog a filter keeps.
enum _Status {
  all('All'),
  installed('Installed'),
  notInstalled('Not installed');

  const _Status(this.label);

  final String label;

  bool keeps(bool installed) => switch (this) {
    _Status.all => true,
    _Status.installed => installed,
    _Status.notInstalled => !installed,
  };
}

class _PublicSkillDialog extends ConsumerStatefulWidget {
  const _PublicSkillDialog();

  @override
  ConsumerState<_PublicSkillDialog> createState() => _PublicSkillDialogState();
}

class _PublicSkillDialogState extends ConsumerState<_PublicSkillDialog> {
  final _search = TextEditingController();
  String _query = '';
  _Status _status = _Status.all;

  /// The skill being read, or null while browsing. One dialog with two faces
  /// rather than a second one stacked on top: the way back is a Back button,
  /// same as the app the user already knows this pattern from.
  PublicSkill? _open;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(PublicSkill skill) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return skill.name.toLowerCase().contains(q) ||
        skill.description.toLowerCase().contains(q) ||
        skill.collection.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final catalog = ref.watch(publicSkillsProvider);
    // A tick means "the assistant you picked already has this" — so it moves
    // when the picker does, and under All agents only both count. Read off the
    // agents' own folders, which is where the question is really asked.
    final target = ref.watch(skillTargetProvider);
    final held = {
      for (final agent in kSkillAgents)
        agent: switch (ref.watch(agentSkillNamesProvider(agent))) {
          AsyncData(:final value) => value,
          _ => const <String>{},
        },
    };
    bool hasIt(PublicSkill skill) =>
        target.agents.every((agent) => held[agent]!.contains(skill.slug));
    final size = MediaQuery.sizeOf(context);
    final open = _open;

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 20),
      title: open == null
          ? _BrowseHeader(onClose: () => Navigator.of(context).pop())
          : _SkillHeader(
              skill: open,
              installed: hasIt(open),
              target: target,
              onBack: () => setState(() => _open = null),
            ),
      content: SizedBox(
        width: math.min(820, size.width * 0.9),
        height: math.min(520, size.height * 0.72),
        child: open != null
            ? SkillFolderView(
                folder: assetSkillFolder('$kPublicSkillRoot/${open.id}'),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ExtensionSearchField(
                          controller: _search,
                          hintText: 'Search skills…',
                          onChanged: (value) => setState(() => _query = value),
                        ),
                      ),
                      const SizedBox(width: 10),
                      for (final option in _Status.values)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: PillChoice(
                            label: Text(option.label),
                            selected: option == _status,
                            onTap: () => setState(() => _status = option),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SkillTargetPicker(inline: true),
                  const SizedBox(height: 12),
                  Expanded(
                    child: switch (catalog) {
                      AsyncData(:final value) => _Gallery(
                        skills: [
                          for (final skill in value)
                            if (_matches(skill) && _status.keeps(hasIt(skill)))
                              skill,
                        ],
                        hasIt: hasIt,
                        onOpen: (skill) => setState(() => _open = skill),
                        filtered:
                            _query.trim().isNotEmpty || _status != _Status.all,
                      ),
                      AsyncError(:final error) => Center(
                        child: Text(
                          "Couldn't read the bundled catalog: $error",
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: AppPalette.textSecondary),
                        ),
                      ),
                      _ => const Center(child: AppSpinner()),
                    },
                  ),
                ],
              ),
      ),
      actions: [
        if (open == null)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          )
        else ...[
          // The folder it would land in, so "where does this go" is answered
          // before the button that puts it there is pressed.
          Expanded(
            child: Text(
              hasIt(open)
                  ? '${target.label} already has it'
                  : 'Installs it for ${target.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint),
            ),
          ),
          const SizedBox(width: 12),
          _InstallButton(skill: open, installed: hasIt(open)),
        ],
      ],
    );
  }
}

class _BrowseHeader extends StatelessWidget {
  const _BrowseHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Public skills',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AppIconButton(
              tooltip: 'Close',
              icon: Icons.close_rounded,
              onPressed: onClose,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Skills that ship with Grid. Open one to read what it does before '
          'you install it.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The header while reading one skill: where you are, and the way back.
class _SkillHeader extends StatelessWidget {
  const _SkillHeader({
    required this.skill,
    required this.installed,
    required this.target,
    required this.onBack,
  });

  final PublicSkill skill;
  final bool installed;
  final ShareTarget target;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BackLink(onTap: onBack),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    skill.name,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      skill.author,
                      if (skill.collection.isNotEmpty) skill.collection,
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            if (installed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ExtensionTag(label: 'On ${target.label}'),
              ),
          ],
        ),
        if (skill.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            skill.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
              height: 1.45,
            ),
          ),
        ],
        if (!installed) ...[
          const SizedBox(height: 12),
          const SkillTargetPicker(inline: true),
        ],
      ],
    );
  }
}

class _BackLink extends StatefulWidget {
  const _BackLink({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_BackLink> createState() => _BackLinkState();
}

class _BackLinkState extends State<_BackLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final ink = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chevron_left_rounded, size: 18, color: ink),
            const SizedBox(width: 2),
            Text(
              'Back',
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFont.medium,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Install, or take it back out again.
class _InstallButton extends ConsumerStatefulWidget {
  const _InstallButton({required this.skill, required this.installed});

  final PublicSkill skill;
  final bool installed;

  @override
  ConsumerState<_InstallButton> createState() => _InstallButtonState();
}

class _InstallButtonState extends ConsumerState<_InstallButton> {
  bool _busy = false;

  Future<void> _run() async {
    final skill = widget.skill;
    setState(() => _busy = true);
    final controller = ref.read(skillsProvider.notifier);
    final failure = widget.installed
        ? await controller.uninstallPublic(skill)
        : await controller.installPublic(skill);
    if (!mounted) return;
    setState(() => _busy = false);
    ToastScope.showResult(
      context,
      error: failure,
      success: widget.installed
          ? '${skill.name} taken off ${ref.read(skillTargetProvider).label}.'
          : '${skill.name} installed, and given to '
                '${ref.read(skillTargetProvider).label}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.installed) {
      return OutlinedButton(
        onPressed: _busy ? null : _run,
        child: Text(_busy ? 'Removing…' : 'Uninstall'),
      );
    }
    return FilledButton(
      onPressed: _busy ? null : _run,
      child: Text(_busy ? 'Installing…' : 'Install'),
    );
  }
}

class _Gallery extends StatelessWidget {
  const _Gallery({
    required this.skills,
    required this.hasIt,
    required this.filtered,
    required this.onOpen,
  });

  final List<PublicSkill> skills;
  final bool Function(PublicSkill) hasIt;
  final bool filtered;
  final ValueChanged<PublicSkill> onOpen;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return EmptyState.noMatches(
        message: filtered
            ? 'No skills match that.'
            : 'The bundled catalog is empty.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns where there's room for two — a card needs about 340px
        // before its description turns into one word a line.
        final columns = constraints.maxWidth >= 700 ? 2 : 1;
        return GridView.builder(
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 116,
          ),
          itemCount: skills.length,
          itemBuilder: (context, index) => _SkillCard(
            skill: skills[index],
            installed: hasIt(skills[index]),
            onOpen: () => onOpen(skills[index]),
          ),
        );
      },
    );
  }
}

class _SkillCard extends ConsumerStatefulWidget {
  const _SkillCard({
    required this.skill,
    required this.installed,
    required this.onOpen,
  });

  final PublicSkill skill;
  final bool installed;
  final VoidCallback onOpen;

  @override
  ConsumerState<_SkillCard> createState() => _SkillCardState();
}

class _SkillCardState extends ConsumerState<_SkillCard> {
  bool _busy = false;
  bool _hovered = false;

  Future<void> _install() async {
    setState(() => _busy = true);
    final failure = await ref
        .read(skillsProvider.notifier)
        .installPublic(widget.skill);
    if (!mounted) return;
    setState(() => _busy = false);
    ToastScope.showResult(
      context,
      error: failure,
      success: '${widget.skill.name} installed, and given to '
          '${ref.read(skillTargetProvider).label}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final skill = widget.skill;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        // The card opens the skill; the + installs it without reading. The
        // inner button wins the tap, so the two never fight.
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: _hovered ? AppGlass.surfaceHoverFill : AppGlass.surfaceFill,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '/${skill.name}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _InstallControl(
                    installed: widget.installed,
                    target: ref.watch(skillTargetProvider),
                    busy: _busy,
                    onInstall: _install,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // Author and plugin, whichever of them the manifest actually gave
              // — a bare " · " on a card whose plugin named no author reads
              // like a missing word.
              Text(
                [
                  if (skill.author.isNotEmpty) skill.author,
                  if (skill.collection.isNotEmpty) skill.collection,
                ].join('  ·  '),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textFaint,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  skill.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one control on a card: give it to the chosen assistant, or say they
/// already have it.
///
/// A tick is a statement, not a button — taking a skill back is done from the
/// skill's own page, where the user can see what they're removing.
class _InstallControl extends StatelessWidget {
  const _InstallControl({
    required this.installed,
    required this.target,
    required this.busy,
    required this.onInstall,
  });

  final bool installed;
  final ShareTarget target;
  final bool busy;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (busy) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Center(child: AppSpinner()),
      );
    }
    if (installed) {
      return Tooltip(
        message: target == ShareTarget.all
            ? 'Both assistants have it'
            : '${target.label} has it',
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(
            Icons.check_rounded,
            size: 16,
            color: AppPalette.textFaint,
          ),
        ),
      );
    }
    return AppIconButton(
      tooltip: 'Add it for ${target.label}',
      icon: Icons.add_rounded,
      onPressed: onInstall,
    );
  }
}
