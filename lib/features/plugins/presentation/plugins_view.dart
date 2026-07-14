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
          TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: tab == PluginsTab.plugins
                  ? 'Search plugins'
                  : 'Search skills',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
            ),
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
            child: ChoiceChip(
              label: Text(option.label),
              selected: option == tab,
              onSelected: (_) =>
                  ref.read(pluginsTabProvider.notifier).select(option),
            ),
          ),
        const Spacer(),
        IconButton(
          tooltip: 'Refresh',
          iconSize: 18,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: onRefresh,
        ),
        const SizedBox(width: 4),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.extension_outlined, size: 18),
              onPressed: () => showAddPluginDialog(context),
              child: const Text('Add a plugin from Git'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.auto_awesome_outlined, size: 18),
              onPressed: () => showNewSkillDialog(context),
              child: const Text('Write a skill'),
            ),
          ],
          builder: (context, controller, _) => FilledButton.icon(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Create'),
          ),
        ),
      ],
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
