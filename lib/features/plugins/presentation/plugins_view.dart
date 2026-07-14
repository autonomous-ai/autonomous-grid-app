import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_skill_installer.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/agent_skill.dart';

/// The Plugins screen: the extra things the assistant can do beyond talking —
/// making an image on your grid, for one — and where each of them came from.
///
/// It reads what's actually installed on this computer rather than a list the app
/// keeps, so a plugin can't show up here unless the assistant can really use it.
class PluginsView extends ConsumerWidget {
  const PluginsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hermesInstalledProvider)) return const _NoAgent();

    final skills = ref.watch(agentSkillsProvider);
    return SectionScaffold(
      title: 'Plugins',
      subtitle:
          'Extra abilities the assistant can use while it answers you. Grid '
          'installs its own; anything you add by hand shows up here too.',
      child: switch (skills) {
        AsyncData(:final value) when value.isEmpty => const _NoPlugins(),
        AsyncData(:final value) => _SkillList(skills: value),
        AsyncError(:final error) => ErrorBox(
          message: "Couldn't read the installed plugins: $error",
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// The installed plugins, with the action that (re)installs Grid's own.
class _SkillList extends ConsumerWidget {
  const _SkillList({required this.skills});

  final List<AgentSkill> skills;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: skills.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _SkillCard(skill: skills[i]),
          ),
        ),
        const SizedBox(height: 14),
        const _ReinstallButton(),
      ],
    );
  }
}

/// One plugin: what it does, where it lives, and who put it there.
class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.skill});

  final AgentSkill skill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.extension_outlined, size: 18),
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
                    if (skill.fromGrid) ...[
                      const SizedBox(width: 8),
                      const _FromGridBadge(),
                    ],
                  ],
                ),
                if (skill.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    skill.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  skill.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textFaint,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FromGridBadge extends StatelessWidget {
  const _FromGridBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'From Grid',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppCard.accentStrong,
        ),
      ),
    );
  }
}

/// Rewrites Grid's own plugins and re-reads the folder. Idempotent, so it's also
/// the fix for a plugin someone deleted or edited by mistake.
class _ReinstallButton extends ConsumerStatefulWidget {
  const _ReinstallButton();

  @override
  ConsumerState<_ReinstallButton> createState() => _ReinstallButtonState();
}

class _ReinstallButtonState extends ConsumerState<_ReinstallButton> {
  bool _busy = false;

  Future<void> _reinstall() async {
    setState(() => _busy = true);
    var message = "Grid's plugins are up to date.";
    try {
      await ref.read(hermesSkillInstallerProvider).install();
      ref.invalidate(agentSkillsProvider);
    } on Object catch (error) {
      message = "Couldn't install Grid's plugins: $error";
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
      label: Text(_busy ? 'Installing…' : "Reinstall Grid's plugins"),
    );
  }
}

/// The agent isn't on this computer, so there's nothing to extend yet.
class _NoAgent extends ConsumerWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Plugins',
      subtitle: 'Extra abilities the assistant can use while it answers you.',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "This computer isn't set up to answer chats yet, so it has "
              'nothing to extend.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.engines),
              child: const Text('Set up this computer'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The agent is installed but has no plugins — offer the one action that fixes
/// it rather than a blank page.
class _NoPlugins extends StatelessWidget {
  const _NoPlugins();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No plugins installed yet.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
          SizedBox(height: 14),
          _ReinstallButton(),
        ],
      ),
    );
  }
}
