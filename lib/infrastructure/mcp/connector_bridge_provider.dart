import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/logic/connector_runtime.dart';
import '../../features/connectors/logic/connector_link_controller.dart';
import '../../features/connectors/logic/connector_token_store.dart';
import 'connector_bridge.dart';

/// The one bridge for the whole app.
///
/// A single server on distinct paths rather than one per connector: agents hold
/// their config across restarts, and a port each would multiply both the sockets
/// and the number of ways an agent's config can go stale.
///
/// Kept in its own file so [ConnectorBridge] itself stays free of Flutter. That
/// is not tidiness: a plain `dart:io` server can be started and driven from a
/// scratch script, which is how its protocol handling was checked against a real
/// socket rather than by reading it.
final connectorBridgeProvider = Provider<ConnectorBridge>((ref) {
  final bridge = ConnectorBridge(
    readTokens: () => ref.read(connectorTokenStoreProvider).read(),
    restEntryFor: effectiveRestEntry,
    // The controller's own renewal, not a second implementation: it is the half
    // that knows a self-registered token is renewed against the provider while
    // a gateway one goes back to the gateway, that a 401 means the credential
    // is gone for good rather than something to retry, and that a renewed token
    // has to be re-projected into every agent. Read lazily, inside the
    // callback — reading a notifier while building this provider would make the
    // bridge a dependency of the controller that disposes it.
    refreshToken: (connector) =>
        ref.read(connectorLinkControllerProvider.notifier).refresh(connector),
  );
  ref.onDispose(bridge.stop);
  return bridge;
});
