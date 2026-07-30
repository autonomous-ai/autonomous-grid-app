import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/anchored_menu_position.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../logic/skill_sharing.dart';
import '../../logic/skills_controller.dart';
import 'skill_menu.dart';

/// Hands a copy of this skill to an agent's own folder.
///
/// Only on the store's rows: sharing a skill *out of* an agent's folder would
/// be copying something the app doesn't own, and the two agents' folders are
/// where it lands.
class ShareSkillButton extends ConsumerStatefulWidget {
  const ShareSkillButton({super.key, required this.skill, required this.busy});

  final AgentSkill skill;
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

  void _toggle(BuildContext context) {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: skillMenuSize(ShareTarget.values.length),
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
              for (final target in ShareTarget.values)
                SkillMenuItem(
                  icon: _iconFor(target),
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

  static IconData _iconFor(ShareTarget target) => switch (target) {
    ShareTarget.hermes => Icons.bolt_outlined,
    ShareTarget.codex => Icons.terminal_rounded,
    ShareTarget.all => Icons.groups_outlined,
  };
}
