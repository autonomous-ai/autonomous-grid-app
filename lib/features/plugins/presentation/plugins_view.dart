import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/agent_skill.dart';
import '../logic/plugins_controller.dart';
import 'widgets/add_plugin_dialog.dart';
import 'widgets/new_skill_dialog.dart';
import 'widgets/plugin_pill_choice.dart';
import 'widgets/plugin_list.dart';
import 'widgets/skill_list.dart';

/// What the assistant can do beyond talking, in two halves.
///
/// **Plugins** are tool backends — a browser it can drive, a search provider it
/// can query — shipped with Hermes or pulled from a Git repo, each with a switch.
/// **Skills** are instructions for one job ("make an image on the grid"), which
/// you can also write yourself.
///
/// Both lists are read from what's really installed, not from a list the app
/// keeps, so nothing can show up here that the assistant can't actually use.
class PluginsView extends ConsumerStatefulWidget {
  const PluginsView({super.key});

  @override
  ConsumerState<PluginsView> createState() => _PluginsViewState();
}

class _PluginsViewState extends ConsumerState<PluginsView> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(String name, String description) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q);
  }

  void _refresh() {
    ref.invalidate(pluginsProvider);
    ref.invalidate(agentSkillsProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hermesInstalledProvider)) return const _NoAgent();

    final tab = ref.watch(pluginsTabProvider);
    return SectionScaffold(
      title: 'Plugins',
      subtitle:
          'What the assistant can do beyond talking: plugins give it new tools, '
          'skills teach it a job.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(tab: tab, onRefresh: _refresh),
          const SizedBox(height: 12),
          _SearchField(
            controller: _search,
            hintText: tab == PluginsTab.plugins
                ? 'Search plugins'
                : 'Search skills',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: tab == PluginsTab.plugins
                ? _Plugins(matches: _matches)
                : _Skills(matches: _matches),
          ),
        ],
      ),
    );
  }
}

/// The tab switch, refresh, and the Create menu (a plugin from Git, or a skill
/// you write yourself).
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.tab, required this.onRefresh});

  final PluginsTab tab;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        for (final option in PluginsTab.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PluginPillChoice(
              label: option.label,
              selected: option == tab,
              icon: option == PluginsTab.plugins
                  ? Icons.extension_rounded
                  : Icons.auto_awesome_rounded,
              onTap: () => ref.read(pluginsTabProvider.notifier).select(option),
            ),
          ),
        const Spacer(),
        _RefreshButton(onPressed: onRefresh),
        const SizedBox(width: 8),
        MenuAnchor(
          alignmentOffset: const Offset(-32, 8),
          menuChildren: [
            _CreateMenuItem(
              icon: Icons.extension_outlined,
              label: 'Add a plugin from Git',
              onPressed: () => showAddPluginDialog(context),
            ),
            _CreateMenuItem(
              icon: Icons.auto_awesome_outlined,
              label: 'Write a skill',
              onPressed: () => showNewSkillDialog(context),
            ),
          ],
          style: MenuStyle(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6),
            ),
            minimumSize: const WidgetStatePropertyAll(Size(184, 0)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: AppPalette.divider),
              ),
            ),
          ),
          builder: (context, controller, _) => _CreateMenuButton(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ],
    );
  }
}

class _CreateMenuButton extends StatelessWidget {
  const _CreateMenuButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.accent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 17, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Create',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateMenuItem extends StatelessWidget {
  const _CreateMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      onPressed: onPressed,
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        minimumSize: WidgetStatePropertyAll(Size(184, 40)),
      ),
      leadingIcon: Icon(icon, size: 17),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Refresh',
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AppPalette.divider),
            ),
            child: const Icon(Icons.refresh_rounded, size: 17),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppGlass.cardShadow,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          filled: false,
          hintText: hintText,
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}

/// The plugins half — Hermes's own list, with a switch each.
class _Plugins extends ConsumerWidget {
  const _Plugins({required this.matches});

  final bool Function(String name, String description) matches;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(pluginsProvider)) {
      AsyncData(:final value) => PluginList(
        plugins: [
          for (final plugin in value)
            if (matches(plugin.name, plugin.description)) plugin,
        ],
      ),
      AsyncError(:final error) => ErrorBox(
        message: "Couldn't read the installed plugins: $error",
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// The skills half — what's in the assistant's skills folder.
class _Skills extends ConsumerWidget {
  const _Skills({required this.matches});

  final bool Function(String name, String description) matches;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(agentSkillsProvider)) {
      AsyncData(:final value) => SkillList(
        skills: [
          for (final skill in value)
            if (matches(skill.name, skill.description)) skill,
        ],
      ),
      AsyncError(:final error) => ErrorBox(
        message: "Couldn't read the installed skills: $error",
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// The agent isn't on this computer, so there's nothing to extend yet.
class _NoAgent extends ConsumerWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Plugins',
      subtitle: 'What the assistant can do beyond talking.',
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
