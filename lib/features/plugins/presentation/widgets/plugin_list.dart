import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/hermes_plugin.dart';
import '../../logic/plugins_controller.dart';
import 'extension_tile_surface.dart';

/// The plugins Hermes knows about: what each one is, and a switch that turns it
/// on for the assistant. A plugin pulled from Git can also be removed; a bundled
/// one can only be switched off (it comes back with Hermes).
class PluginList extends StatelessWidget {
  const PluginList({super.key, required this.plugins});

  final List<HermesPlugin> plugins;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    if (plugins.isEmpty) {
      return Center(
        child: Text(
          'No plugins match that.',
          style: TextStyle(color: AppPalette.textFaint),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: plugins.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _PluginRow(plugin: plugins[i]),
    );
  }
}

class _PluginRow extends ConsumerStatefulWidget {
  const _PluginRow({required this.plugin});

  final HermesPlugin plugin;

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
          const ExtensionIconBadge(icon: Icons.extension_outlined),
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
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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
                      const ExtensionTag(label: 'From Git'),
                    ],
                  ],
                ),
                if (plugin.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    plugin.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
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
              color: value ? AppPalette.accent : AppPalette.offline,
              borderRadius: BorderRadius.circular(999),
              boxShadow: value ? AppGlass.cardShadow : null,
            ),
            child: busy
                ? const Center(
                    child: AppSpinner.onAccent(),
                  )
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
