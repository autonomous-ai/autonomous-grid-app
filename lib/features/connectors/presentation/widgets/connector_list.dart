import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/widgets/extension_list.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../agents/logic/mcp_server.dart';
import '../../logic/connector.dart';
import '../../logic/connector_catalog.dart';
import '../../logic/connector_link_controller.dart';
import '../../logic/connectors_controller.dart';
import 'add_mcp_dialog.dart';

/// Everything that links the assistant to the outside: the MCP servers live in
/// the agent's config (each adds a set of tools — a database, a design tool, a
/// search provider), and under them the catalog services a future sign-in will
/// connect in one step.
class ConnectorList extends StatelessWidget {
  const ConnectorList({
    super.key,
    required this.connectors,
    this.filtered = false,
  });

  final List<Connector> connectors;

  /// A search or a status pill is narrowing the list, so an empty [connectors]
  /// means "nothing matched" — not "nothing configured".
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (connectors.isEmpty) {
      return filtered
          ? const EmptyState.noMatches(
              message: 'No connectors match that search.',
            )
          : const _Empty();
    }
    final sections = sectionExtensionItems(
      items: connectors,
      sectionOf: (c) => c.connected ? 'Connected' : 'Available',
      leading: const ['Connected', 'Available'],
      filtered: filtered,
    );
    return ExtensionList(
      sections: sections,
      rowBuilder: (context, connector) => switch (connector.server) {
        final McpServer server => _McpRow(
          server: server,
          imageUrl: connector.imageUrl,
        ),
        null => _CatalogRow(connector: connector),
      },
    );
  }
}

/// A catalog service, with whatever action its current state allows.
///
/// Connect is offered only when the gateway can actually drive a sign-in *and*
/// there is an MCP server behind it. A `pat` connector has no flow to call, and
/// a connector with no MCP server links an account that the agent still cannot
/// use — walking a whole OAuth round trip to arrive at nothing is worse than a
/// button that visibly isn't ready.
class _CatalogRow extends ConsumerStatefulWidget {
  const _CatalogRow({required this.connector});

  final Connector connector;

  @override
  ConsumerState<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends ConsumerState<_CatalogRow> {
  bool _busy = false;

  Future<void> _connect() async {
    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .connect(widget.connector.id);
    if (mounted) setState(() => _busy = false);
    // Only a failure to *start* is worth a toast. Everything that happens after
    // the browser opens — cancelled, timed out, refused — the row says quietly
    // itself, because none of it is a surprise the user needs interrupting for.
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  /// Hand the credential back: forgotten at the gateway, then here, then
  /// removed from the agent's config by the re-projection.
  ///
  /// Confirmed first, and the wording has to be honest that this does not
  /// revoke anything at the provider — only the user can do that, in the
  /// provider's own settings.
  Future<void> _disconnect() async {
    final toast = ToastScope.of(context);
    final connector = widget.connector;
    final confirmed = await _confirmDisconnect(context, connector.name);
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .disconnect(connector.id);
    if (mounted) setState(() => _busy = false);
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    final connector = widget.connector;
    final link = ref.watch(connectorLinkControllerProvider);
    final waiting = link.isPending(connector.id);
    // A line the row owns: what this connector is waiting for, or how its last
    // attempt ended.
    final note = link.messageFor(connector.id).isNotEmpty
        ? link.messageFor(connector.id)
        : connector.linkedElsewhere
        ? 'Connected on another computer — sign in here to use it.'
        : !connector.canConnect && connector.catalogEntry != null
        ? _unavailableReason(connector)
        : '';

    return ExtensionTileSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConnectorMark(
            imageUrl: connector.imageUrl,
            fallbackIcon: Icons.cloud_outlined,
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
                        connector.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(),
                      ),
                    ),
                    // Signed in on this machine. Shown even before the agent
                    // has an MCP server for it, because the credential is the
                    // part the user just did and the row has to acknowledge it.
                    if (connector.token != null) ...[
                      const SizedBox(width: 8),
                      const ExtensionTag(label: 'Connected'),
                    ],
                    if (connector.connectedButUnusable) ...[
                      const SizedBox(width: 8),
                      const ExtensionTag(label: 'No tools yet', muted: true),
                    ],
                  ],
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ] else if (connector.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // One line, like every other extension row. The backend's
                  // blurb runs to a paragraph — the full text is the tooltip.
                  Tooltip(
                    message: connector.description,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      connector.description,
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
          const SizedBox(width: 8),
          _CatalogAction(
            connector: connector,
            waiting: waiting,
            busy: _busy,
            onConnect: _connect,
            onCancel: () =>
                ref.read(connectorLinkControllerProvider.notifier).cancel(),
            onDisconnect: _disconnect,
          ),
        ],
      ),
    );
  }
}

/// The one control a catalog row offers, chosen by state.
class _CatalogAction extends StatelessWidget {
  const _CatalogAction({
    required this.connector,
    required this.waiting,
    required this.busy,
    required this.onConnect,
    required this.onCancel,
    required this.onDisconnect,
  });

  final Connector connector;

  /// This row is the one waiting on a browser right now.
  final bool waiting;

  /// A request is in flight for this row (starting the link).
  final bool busy;

  final VoidCallback onConnect;
  final VoidCallback onCancel;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.

    // While the browser is open the way out is Cancel, not a spinner: the user
    // may have closed the tab, and a control that only spins would strand them.
    if (waiting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(),
          const SizedBox(width: 8),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      );
    }
    if (busy) return const AppSpinner();

    // Already signed in here: the useful action is undoing it. Offering Connect
    // again would read as the sign-in not having taken, and pressing it would
    // discard a working credential to fetch the same one.
    if (connector.token != null) {
      return TextButton(
        onPressed: onDisconnect,
        child: const Text('Disconnect'),
      );
    }

    // Nothing to press when the gateway can't drive this connector: the row
    // already says why, and a button that only ever fails is a worse answer
    // than no button.
    if (!connector.canConnect) return const SizedBox.shrink();

    return FilledButton(onPressed: onConnect, child: const Text('Connect'));
  }
}

class _McpRow extends ConsumerStatefulWidget {
  const _McpRow({required this.server, this.imageUrl = ''});

  final McpServer server;

  /// The catalog's mark when this server matched one; empty for a server the
  /// user configured by hand, and the row falls back to a transport glyph.
  final String imageUrl;

  @override
  ConsumerState<_McpRow> createState() => _McpRowState();
}

class _McpRowState extends ConsumerState<_McpRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final server = widget.server;
    final confirmed = await _confirmRemove(context, server.name);
    if (confirmed != true || !mounted) return;

    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(mcpServersProvider.notifier)
        .remove(server.name);
    if (mounted) setState(() => _busy = false);
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : ToastSpec(
              message: '${server.name} removed.',
              severity: ToastSeverity.success,
            ),
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
          ConnectorMark(
            imageUrl: widget.imageUrl,
            fallbackIcon: _transportIcon(server.transport),
          ),
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
                style: theme.textTheme.titleSmall?.copyWith(),
              ),
            ),
            const SizedBox(width: 8),
            ExtensionTag(label: server.transport is McpHttp ? 'HTTP' : 'Local'),
          ],
        ),
        const SizedBox(height: 4),
        // One line, like the plugin and skill rows — a stdio server's command
        // line with its args is long, and wrapping it to two made the MCP rows
        // taller than everything else in the app.
        Tooltip(
          message: mcpServerSummary(server),
          waitDuration: const Duration(milliseconds: 600),
          child: Text(
            mcpServerSummary(server),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
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

/// Disconnecting hands back the credential this machine holds.
///
/// The second sentence is the one that matters: this clears the token here and
/// at the gateway, and it does **not** revoke the access granted at the
/// provider. Only the user can do that, in the provider's own settings, and a
/// dialog that let them believe otherwise would leave access standing that they
/// think they withdrew.
Future<bool?> _confirmDisconnect(BuildContext context, String name) {
  final scheme = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Disconnect $name?'),
      content: Text(
        'The assistant will stop using $name on this computer. Your account '
        'keeps whatever access you granted — remove it in $name\'s own '
        'settings to revoke it fully.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            // Named rather than left to `onError`, which this app's scheme
            // never sets: the Material default lands at 3.83:1 on the dark
            // error red, under the 4.5:1 floor.
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Disconnect'),
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
    return EmptyState(
      icon: Icons.hub_outlined,
      title: 'No MCP servers yet',
      message:
          'Add one to give the assistant tools from outside — a database, a '
          'design tool, a web service.',
      action: FilledButton.icon(
        onPressed: () => showAddMcpDialog(context),
        icon: const Icon(Icons.add_rounded, size: AppControl.iconSize),
        label: const Text('Add an MCP server'),
      ),
    );
  }
}

/// The service's own logo, or the glyph badge when there isn't one.
///
/// Same 30px well as [ExtensionIconBadge] so the icon column stays a column
/// whichever kind of row is in it. The image is a fact about the service, not
/// live state, so it never takes the accent tint.
///
/// Every failure path lands on the glyph: no URL, a URL that won't load, a
/// user offline. A blank square in the icon column reads as a broken row.
class ConnectorMark extends StatelessWidget {
  const ConnectorMark({
    super.key,
    required this.imageUrl,
    required this.fallbackIcon,
  });

  final String imageUrl;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    if (imageUrl.isEmpty) return ExtensionIconBadge(icon: fallbackIcon);
    return Container(
      width: 30,
      height: 30,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // A white plate under every logo: these are the services' own marks,
        // each with its own backdrop, and half of them are dark-on-transparent
        // — on the dark card fill they would disappear.
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          fit: BoxFit.contain,
          // No spinner while it loads: the plate is already the right shape,
          // and a spinner per row turns a quiet list into a flicker.
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) =>
              Icon(fallbackIcon, size: 16, color: AppPalette.textSecondary),
        ),
      ),
    );
  }
}

/// Why a catalog row can't be connected from here.
///
/// Both cases are real and neither is the user's doing, so the row explains
/// itself rather than leaving a dead button to be discovered by pressing it.
String _unavailableReason(Connector connector) {
  final entry = connector.catalogEntry;
  if (entry == null) return '';
  if (entry.authMethod != ConnectorAuthMethod.app) {
    return 'Needs a personal access token — not available from the app yet.';
  }
  if (!entry.mcpReady) {
    return 'No tools available for this connector yet.';
  }
  return '';
}
