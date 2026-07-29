import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/connector.dart';
import '../logic/connector_catalog.dart';
import '../logic/connector_link_controller.dart';
import '../logic/connectors_controller.dart';
import 'widgets/add_mcp_dialog.dart';
import 'widgets/connector_list.dart';

/// What connects the assistant to the outside: the MCP servers in the agent's
/// config, and the catalog of services a future sign-in will connect in one
/// step. The config is the only truth about what's live — the catalog only
/// adds "available" rows under it.
class ConnectorsView extends ConsumerStatefulWidget {
  const ConnectorsView({super.key});

  @override
  ConsumerState<ConnectorsView> createState() => _ConnectorsViewState();
}

enum _ConnectorFilter {
  all('All'),
  connected('Connected'),
  available('Available');

  const _ConnectorFilter(this.label);

  final String label;

  bool keeps(Connector connector) => switch (this) {
    all => true,
    connected => connector.connected,
    available => !connector.connected,
  };
}

class _ConnectorsViewState extends ConsumerState<ConnectorsView> {
  _ConnectorFilter _filter = _ConnectorFilter.all;

  @override
  Widget build(BuildContext context) {
    return ExtensionScreen(
      title: 'Connectors',
      subtitle:
          'Connect the assistant to tools outside this computer — a database, '
          'a design tool, a web service.',
      searchHint: 'Search connectors',
      createLabel: 'Add an MCP server',
      onCreate: showAddMcpDialog,
      // All three sources, not just the config. The screen joins the agent's
      // MCP servers, the gateway's catalog and this machine's tokens; a refresh
      // that re-read one of them would leave the row showing two-thirds stale
      // data and look like the button did nothing.
      onRefresh: () {
        ref.invalidate(mcpServersProvider);
        ref.invalidate(connectorCatalogProvider);
        ref.invalidate(connectorTokensProvider);
      },
      filterBar: Row(
        children: [
          for (final option in _ConnectorFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChoice(
                label: Text(option.label),
                selected: option == _filter,
                onTap: () => setState(() => _filter = option),
              ),
            ),
        ],
      ),
      listBuilder: (context, {required filtered, required matches}) {
        return switch (ref.watch(connectorsProvider)) {
          AsyncData(:final value) => ConnectorList(
            // A status pill narrows the list just like a search does: sections
            // collapse (they'd all be one status anyway) and an empty result
            // reads as "nothing matched", not "nothing configured".
            filtered: filtered || _filter != _ConnectorFilter.all,
            connectors: [
              for (final connector in value)
                if (_filter.keeps(connector) &&
                    matches(connector.name, connector.description))
                  connector,
            ],
          ),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read the connectors: $error",
          ),
          _ => const ExtensionLoadingRows(),
        };
      },
    );
  }
}
