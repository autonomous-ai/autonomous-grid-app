import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_plugin.dart';
import '../../logic/plugins_controller.dart';
import '../../../../shared/widgets/extension_list.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';

/// The plugins Hermes knows about: what each one is, and a switch that turns it
/// on for the assistant. A plugin pulled from Git can also be removed; a bundled
/// one can only be switched off (it comes back with Hermes).
class PluginList extends StatelessWidget {
  const PluginList({super.key, required this.plugins, this.filtered = false});

  final List<AgentPlugin> plugins;

  /// A search is narrowing the list, so an empty [plugins] means "nothing
  /// matched". Empty with no search means Hermes reported no plugins at all —
  /// rare, but it shouldn't read as a failed search.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (plugins.isEmpty) {
      return filtered
          ? const EmptyState.noMatches(message: 'No plugins match that search.')
          : const EmptyState(
              icon: Icons.extension_outlined,
              title: 'No plugins installed',
              message:
                  'The assistant reported no plugins on this computer. Add one '
                  'from a Git repository to give it a new tool.',
            );
    }
    // Enabled plugins first, under their own headers. Hermes ships ~60 of
    // these and all but a few are off, so an alphabetical wall buries the
    // handful that are actually loaded among rows that do nothing. "What is my
    // assistant running?" is the question this screen exists to answer, and it
    // should be answerable without reading sixty switches.
    final sections = sectionExtensionItems(
      items: plugins,
      sectionOf: (p) => p.enabled ? 'On' : 'Available',
      leading: const ['On', 'Available'],
      filtered: filtered,
    );
    return ExtensionList(
      sections: sections,
      rowBuilder: (context, plugin) => _PluginRow(plugin: plugin),
    );
  }
}

class _PluginRow extends ConsumerStatefulWidget {
  const _PluginRow({required this.plugin});

  final AgentPlugin plugin;

  @override
  ConsumerState<_PluginRow> createState() => _PluginRowState();
}

class _PluginRowState extends ConsumerState<_PluginRow> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function() action, String done) async {
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    ToastScope.showResult(context, error: error, success: done);
  }

  Future<void> _toggle(bool enabled) => _run(
    () => ref
        .read(pluginsProvider.notifier)
        .setEnabled(widget.plugin.name, enabled: enabled),
    enabled ? '${widget.plugin.name} is on.' : '${widget.plugin.name} is off.',
  );

  Future<void> _remove() => _run(
    () => ref.read(pluginsProvider.notifier).remove(widget.plugin.name),
    '${widget.plugin.name} removed.',
  );

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExtensionIconBadge(
            icon: Icons.extension_outlined,
            active: plugin.enabled,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        plugin.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(),
                      ),
                    ),
                    if (plugin.version.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        plugin.version,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textFaint,
                        ),
                      ),
                    ],
                    if (!plugin.bundled) ...[
                      const SizedBox(width: 8),
                      const ExtensionTag(label: 'From Git', muted: true),
                    ],
                  ],
                ),
                if (plugin.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // One line, so every row is the same height and the list keeps
                  // a rhythm to scan. Some plugins ship a paragraph with URLs and
                  // env-var names in it; at two lines those rows grew half again
                  // as tall and broke the column. The full text is the tooltip.
                  Tooltip(
                    message: plugin.description,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      plugin.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!plugin.bundled)
            IconButton(
              tooltip: 'Remove',
              iconSize: 18,
              color: AppPalette.textSecondary,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _busy ? null : _remove,
            ),
          _PluginSwitch(value: plugin.enabled, busy: _busy, onChanged: _toggle),
        ],
      ),
    );
  }
}

class _PluginSwitch extends StatelessWidget {
  const _PluginSwitch({
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette/AppGlass
    final label = value ? 'Turn off plugin' : 'Turn on plugin';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        toggled: value,
        label: label,
        child: GestureDetector(
          onTap: busy ? null : () => onChanged(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 46,
            height: 28,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              // The off track must stay a solid grey, matching the app's own
              // switchTheme. A translucent well (AppSurface.recess) is 3% black —
              // near-white in light mode — and the white thumb vanished into it:
              // the switch stopped saying which way it was set. Saturation and
              // contrast are separate jobs; the thumb needs the second one.
              color: value ? AppPalette.accent : AppPalette.offline,
              borderRadius: BorderRadius.circular(999),
              boxShadow: value ? AppGlass.cardShadow : null,
            ),
            child: busy
                ? const Center(child: AppSpinner.onAccent())
                : AnimatedAlign(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    alignment: value
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
