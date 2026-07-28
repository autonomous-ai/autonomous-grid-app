import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/skeleton.dart';
import '../logic/connector.dart';
import '../logic/connectors_controller.dart';

/// Third-party apps the assistant can act in — Linear, Slack, Notion and the
/// rest.
///
/// Connecting opens your browser to the app's own consent screen; nothing is
/// typed in here and no password ever reaches this window. What comes back is
/// written to `~/.grid/config_mcp.json`, which is what the assistant reads — so
/// this list reflects what it can really use, not what we hope it can.
class ConnectorsView extends ConsumerWidget {
  const ConnectorsView({super.key});

  Future<void> _connect(
    BuildContext context,
    WidgetRef ref,
    Connector connector,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Finish authorizing ${connector.label} in your browser, then come back.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
    final error = await ref.read(connectorsProvider.notifier).connect(connector.code);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? '${connector.label} connected.'),
        backgroundColor: error != null ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _disconnect(
    BuildContext context,
    WidgetRef ref,
    Connector connector,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Disconnect ${connector.label}?'),
        // Be straight about the limit: we can drop our copy of the token, but
        // only the provider can revoke the grant.
        content: Text(
          'The assistant will lose access to ${connector.label}. To fully revoke '
          'access, also remove the app in your ${connector.label} account settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final error = await ref.read(connectorsProvider.notifier).disconnect(connector.code);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? '${connector.label} disconnected.'),
        backgroundColor: error != null ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectors = ref.watch(connectorsProvider);
    final connecting = ref.watch(connectingConnectorProvider);

    return SectionScaffold(
      title: 'Connectors',
      subtitle:
          'Apps the assistant can work in. Connecting happens in your browser — '
          'nothing is typed in here.',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940),
          child: connectors.when(
            loading: () => const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Skeleton(height: 64),
                SizedBox(height: 8),
                Skeleton(height: 64),
                SizedBox(height: 8),
                Skeleton(height: 64),
              ],
            ),
            error: (error, _) => ErrorBox(message: error.toString()),
            data: (rows) {
              if (rows.isEmpty) {
                return EmptyState(
                  icon: LucideIcons.plug,
                  title: 'No connectors available',
                  message:
                      'None are configured for this Grid yet. Check back after an update.',
                  action: TextButton.icon(
                    onPressed: () => ref.read(connectorsProvider.notifier).refresh(),
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: const Text('Refresh'),
                  ),
                );
              }
              // Connectable first, then connected, then the ones we can't drive
              // yet — so the actionable rows are never buried.
              final sorted = [...rows]..sort((a, b) {
                int rank(Connector c) =>
                    c.connected ? 0 : (c.supported ? 1 : 2);
                final byRank = rank(a).compareTo(rank(b));
                return byRank != 0 ? byRank : a.label.compareTo(b.label);
              });
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => ref.read(connectorsProvider.notifier).refresh(),
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('Refresh'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final connector in sorted) ...[
                    _ConnectorRow(
                      connector: connector,
                      busy: connecting == connector.code,
                      // One authorization at a time: the CLI owns the browser
                      // and the poll loop for the one in flight.
                      locked: connecting != null && connecting != connector.code,
                      onConnect: () => _connect(context, ref, connector),
                      onDisconnect: () => _disconnect(context, ref, connector),
                      onCancel: () =>
                          ref.read(connectorsProvider.notifier).cancelConnect(),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ConnectorRow extends StatelessWidget {
  const _ConnectorRow({
    required this.connector,
    required this.busy,
    required this.locked,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCancel,
  });

  final Connector connector;
  final bool busy;
  final bool locked;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = connector.unsupportedReason;
    final subtitle = busy
        ? 'Waiting for you to authorize in the browser…'
        : connector.connected
        ? (connector.accountName.isNotEmpty
              ? 'Connected · ${connector.accountName}'
              : 'Connected')
        : (reason ?? 'Not connected');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            connector.connected ? LucideIcons.circleCheck : LucideIcons.plug,
            size: 20,
            color: connector.connected
                ? Colors.green
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(connector.label, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (busy)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            )
          else if (connector.connected)
            TextButton(
              onPressed: locked ? null : onDisconnect,
              child: const Text('Disconnect'),
            )
          else
            FilledButton(
              // A connector with no MCP server would authorize and then do
              // nothing, so the button is disabled rather than misleading.
              onPressed: (locked || !connector.supported) ? null : onConnect,
              child: const Text('Connect'),
            ),
        ],
      ),
    );
  }
}
