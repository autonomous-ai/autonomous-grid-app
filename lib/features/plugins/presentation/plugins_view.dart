import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/agent_skill.dart';
import '../logic/mcp_controller.dart';
import '../logic/mcp_server.dart';
import '../logic/plugins_controller.dart';
import 'widgets/add_mcp_dialog.dart';
import 'widgets/add_plugin_dialog.dart';
import 'widgets/mcp_list.dart';
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

  /// Whether a search is narrowing the lists — so an empty list can say "nothing
  /// matched" instead of "nothing installed".
  bool get _isFiltering => _query.trim().isNotEmpty;

  bool _matches(String name, String description) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q);
  }

  void _refresh() {
    ref.invalidate(pluginsProvider);
    ref.invalidate(agentSkillsProvider);
    ref.invalidate(mcpServersProvider);
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
      // Rows are name-on-the-left, switch-on-the-right. Let them run the full
      // width of a large window and the two ends drift so far apart that the eye
      // has to travel to pair them up; this keeps a row scannable in one glance.
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Toolbar(tab: tab, onRefresh: _refresh),
              const SizedBox(height: 12),
              _SearchField(
                controller: _search,
                hintText: switch (tab) {
                  PluginsTab.plugins => 'Search plugins',
                  PluginsTab.skills => 'Search skills',
                  PluginsTab.mcp => 'Search MCP servers',
                },
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: switch (tab) {
                  PluginsTab.plugins => _Plugins(
                    matches: _matches,
                    filtered: _isFiltering,
                  ),
                  PluginsTab.skills => _Skills(
                    matches: _matches,
                    filtered: _isFiltering,
                  ),
                  PluginsTab.mcp => _Mcp(
                    matches: _matches,
                    filtered: _isFiltering,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tab's pill icon.
IconData _tabIcon(PluginsTab tab) => switch (tab) {
  PluginsTab.plugins => Icons.extension_rounded,
  PluginsTab.skills => Icons.auto_awesome_rounded,
  PluginsTab.mcp => Icons.hub_rounded,
};

/// The tab switch, refresh, and the Create menu (a plugin from Git, a skill you
/// write yourself, or an MCP server).
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
              icon: _tabIcon(option),
              onTap: () => ref.read(pluginsTabProvider.notifier).select(option),
            ),
          ),
        const Spacer(),
        _RefreshButton(onPressed: onRefresh),
        const SizedBox(width: 8),
        MenuAnchor(
          alignmentOffset: const Offset(-70, 8),
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
            _CreateMenuItem(
              icon: Icons.hub_outlined,
              label: 'Add an MCP server',
              onPressed: () => showAddMcpDialog(context),
            ),
          ],
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6),
            ),
            minimumSize: const WidgetStatePropertyAll(Size(184, 0)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          builder: (context, controller, _) => _CreateMenuButton(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
        const SizedBox(width: 14),
      ],
    );
  }
}

class _CreateMenuButton extends StatelessWidget {
  const _CreateMenuButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // follow theme flips — reads AppPalette/AppGlass tokens.
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
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return Tooltip(
      message: 'Refresh',
      child: Material(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              boxShadow: AppGlass.cardShadow,
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
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
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
  const _Plugins({required this.matches, required this.filtered});

  final bool Function(String name, String description) matches;
  final bool filtered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(pluginsProvider)) {
      AsyncData(:final value) => PluginList(
        filtered: filtered,
        plugins: [
          for (final plugin in value)
            if (matches(plugin.name, plugin.description)) plugin,
        ],
      ),
      AsyncError(:final error) => ErrorBox(
        message: "Couldn't read the installed plugins: $error",
      ),
      _ => const _LoadingRows(),
    };
  }
}

/// The skills half — what's in the assistant's skills folder.
class _Skills extends ConsumerWidget {
  const _Skills({required this.matches, required this.filtered});

  final bool Function(String name, String description) matches;
  final bool filtered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(agentSkillsProvider)) {
      AsyncData(:final value) => SkillList(
        filtered: filtered,
        skills: [
          for (final skill in value)
            if (matches(skill.name, skill.description)) skill,
        ],
      ),
      AsyncError(:final error) => ErrorBox(
        message: "Couldn't read the installed skills: $error",
      ),
      _ => const _LoadingRows(),
    };
  }
}

/// The MCP half — the external tool servers Hermes is configured to load.
class _Mcp extends ConsumerWidget {
  const _Mcp({required this.matches, required this.filtered});

  final bool Function(String name, String description) matches;
  final bool filtered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(mcpServersProvider)) {
      AsyncData(:final value) => McpList(
        filtered: filtered,
        servers: [
          for (final server in value)
            if (matches(server.name, mcpServerSummary(server))) server,
        ],
      ),
      AsyncError(:final error) => ErrorBox(
        message: "Couldn't read the MCP servers: $error",
      ),
      _ => const _LoadingRows(),
    };
  }
}

/// The three lists all load the same shape — an icon, a name, a line of
/// description — so they wait as rows rather than as a spinner: nothing jumps
/// when the real list lands.
class _LoadingRows extends StatelessWidget {
  const _LoadingRows();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.topCenter,
      child: SkeletonList(rows: 7),
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
      subtitle: 'What the assistant can do beyond talking.',
      child: EmptyState(
        icon: Icons.extension_off_outlined,
        title: 'No assistant on this computer',
        message:
            "This computer isn't set up to answer chats yet, so it has "
            'nothing to extend.',
        action: FilledButton(
          onPressed: () => ref
              .read(shellSectionProvider.notifier)
              .select(ShellSection.engines),
          child: const Text('Set up this computer'),
        ),
      ),
    );
  }
}
