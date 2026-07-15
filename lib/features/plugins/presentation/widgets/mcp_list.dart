import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/mcp_controller.dart';
import '../../logic/mcp_server.dart';
import 'add_mcp_dialog.dart';
import 'extension_tile_surface.dart';

/// The MCP servers Hermes is configured to load — each one adds a set of tools
/// from the MCP ecosystem (a database, a design tool, a search provider).
///
/// Read from Hermes's own config, so a server listed here is one the agent will
/// actually connect to on its next session.
class McpList extends StatelessWidget {
  const McpList({super.key, required this.servers});

  final List<McpServer> servers;

  @override
  Widget build(BuildContext context) {
    if (servers.isEmpty) return const _Empty();
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: servers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _McpRow(server: servers[i]),
    );
  }
}

class _McpRow extends ConsumerStatefulWidget {
  const _McpRow({required this.server});

  final McpServer server;

  @override
  ConsumerState<_McpRow> createState() => _McpRowState();
}

class _McpRowState extends ConsumerState<_McpRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final server = widget.server;
    final confirmed = await _confirmRemove(context, server.name);
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(mcpServersProvider.notifier)
        .remove(server.name);
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? '${server.name} removed.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final server = widget.server;
    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExtensionIconBadge(icon: _transportIcon(server.transport)),
          const SizedBox(width: 12),
          Expanded(child: _McpInfo(server: server)),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Edit',
            iconSize: 18,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.edit_outlined),
            onPressed: _busy ? null : () => showEditMcpDialog(context, server),
          ),
          IconButton(
            tooltip: 'Remove',
            iconSize: 18,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _busy ? null : _delete,
          ),
        ],
      ),
    );
  }
}

/// The server's name, a tag for how it's reached, and the command or URL under
/// it so the user can tell two servers apart at a glance.
class _McpInfo extends StatelessWidget {
  const _McpInfo({required this.server});

  final McpServer server;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                server.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ExtensionTag(label: server.transport is McpHttp ? 'HTTP' : 'Local'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          mcpServerSummary(server),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

IconData _transportIcon(McpTransport transport) => switch (transport) {
  McpStdio() => Icons.terminal_rounded,
  McpHttp() => Icons.cloud_outlined,
};

/// Removing a server stops the assistant using its tools — reversible (add it
/// back), but worth a beat so a stray click doesn't drop a configured server.
Future<bool?> _confirmRemove(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Remove this MCP server?'),
      content: Text(
        '"$name" will be removed from Hermes\'s config and the assistant will '
        'stop using its tools. You can add it again later.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

/// No servers yet — say what MCP is for, and offer the one action that fixes it.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'No MCP servers yet. Add one to give the assistant tools from '
              'outside — a database, a design tool, a web service.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => showAddMcpDialog(context),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('Add an MCP server'),
          ),
        ],
      ),
    );
  }
}
