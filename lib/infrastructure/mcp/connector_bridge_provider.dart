import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/logic/connector_runtime.dart';
import '../../features/connectors/logic/connector_token_store.dart';
import 'connector_bridge.dart';

/// The one bridge for the whole app.
///
/// A single server on distinct paths rather than one per connector: agents hold
/// their config across restarts, and a port each would multiply both the sockets
/// and the number of ways an agent's config can go stale.
///
/// Renewal is wired in by `ConnectorRefreshScope` before it starts the bridge,
/// not here: the half that knows how to renew is the connector link
/// controller, and every agent adapter reads this provider for its endpoint —
/// naming the controller here would close a loop through the agents feature.
///
/// Kept in its own file so [ConnectorBridge] itself stays free of Flutter. That
/// is not tidiness: a plain `dart:io` server can be started and driven from a
/// scratch script, which is how its protocol handling was checked against a real
/// socket rather than by reading it.
final connectorBridgeProvider = Provider<ConnectorBridge>((ref) {
  final bridge = ConnectorBridge(
    readTokens: () => ref.read(connectorTokenStoreProvider).read(),
    restEntryFor: effectiveRestEntry,
  );
  ref.onDispose(bridge.stop);
  return bridge;
});
