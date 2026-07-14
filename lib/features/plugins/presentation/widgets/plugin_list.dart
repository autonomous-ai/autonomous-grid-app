import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../logic/hermes_plugin.dart';
import '../../logic/plugins_controller.dart';

/// The plugins Hermes knows about: what each one is, and a switch that turns it
/// on for the assistant. A plugin pulled from Git can also be removed; a bundled
/// one can only be switched off (it comes back with Hermes).
class PluginList extends StatelessWidget {
  const PluginList({super.key, required this.plugins});

  final List<HermesPlugin> plugins;

  @override
  Widget build(BuildContext context) {
    if (plugins.isEmpty) {
      return const Center(
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? done)));
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
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.extension_outlined, size: 18),
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
                      const _Tag(label: 'From Git'),
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
          Switch(value: plugin.enabled, onChanged: _busy ? null : _toggle),
        ],
      ),
    );
  }
}

/// A small caption chip — where a plugin came from.
class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppCard.accentStrong,
        ),
      ),
    );
  }
}
