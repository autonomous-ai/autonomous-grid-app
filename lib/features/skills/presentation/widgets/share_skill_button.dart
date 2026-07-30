import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/anchored_menu_position.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/skills/agent_skill_home.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../../agents/presentation/agent_mark.dart';
import '../../logic/skill_sharing.dart';
import '../../logic/skills_controller.dart';
import 'skill_menu.dart';

/// Hands a copy of this skill to another assistant's own folder.
///
/// The one way a skill crosses between assistants: they read different roots
/// and neither can be pointed at the other's, so the app copies the folder
/// across. Overwrites whatever is there under that name — sharing again is how
/// a stale copy is caught up.
class ShareSkillButton extends ConsumerStatefulWidget {
  const ShareSkillButton({
    super.key,
    required this.skill,
    required this.from,
    required this.busy,
  });

  final AgentSkill skill;

  /// The tab the row is in. Its own assistant already has the skill, so the
  /// menu offers the others — and "all agents" only when there is more than
  /// one other to mean.
  final SkillSource from;

  final bool busy;

  @override
  ConsumerState<ShareSkillButton> createState() => _ShareSkillButtonState();
}

class _ShareSkillButtonState extends ConsumerState<ShareSkillButton> {
  final _menu = MenuController();
  bool _sharing = false;

  Future<void> _share(ShareTarget target) async {
    _menu.close();
    setState(() => _sharing = true);
    final failure = await ref
        .read(skillsProvider.notifier)
        .share(widget.skill, target);
    if (!mounted) return;
    setState(() => _sharing = false);
    ToastScope.showResult(
      context,
      error: failure,
      success: '${widget.skill.name} copied to ${target.label}.',
    );
  }

  /// The rows this menu shows: every assistant but the one whose tab this is,
  /// plus "all agents" while that still names more than the single other.
  List<ShareTarget> get _targets {
    final mine = widget.from.agent;
    return [
      for (final target in ShareTarget.values)
        if (target != ShareTarget.all && !target.agents.contains(mine)) target,
      if (kSkillAgents.length > 2) ShareTarget.all,
    ];
  }

  void _toggle(BuildContext context) {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: skillMenuSize(_targets.length),
        margin: 8,
        gap: 6,
        // The button sits near the row's trailing edge.
        alignEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: skillMenuStyle(),
      menuChildren: [
        SizedBox(
          width: kSkillMenuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final target in _targets)
                SkillMenuItem(
                  // A row naming one agent carries that agent's own logo — the
                  // mark it goes by everywhere else in the app. "All agents"
                  // names no one in particular, so it keeps a glyph, which also
                  // lets it follow the row's ink on hover the way a logo can't.
                  icon: target == ShareTarget.all
                      ? Icons.groups_outlined
                      : null,
                  leading: target == ShareTarget.all
                      ? null
                      : AgentMark(tool: target.agents.single, size: 15),
                  label: 'Share to ${target.label}',
                  onPressed: () => _share(target),
                ),
            ],
          ),
        ),
      ],
      builder: (context, controller, _) => AppIconButton(
        tooltip: 'Share with an agent',
        icon: Icons.ios_share_rounded,
        onPressed: (widget.busy || _sharing) ? null : () => _toggle(context),
      ),
    );
  }
}
