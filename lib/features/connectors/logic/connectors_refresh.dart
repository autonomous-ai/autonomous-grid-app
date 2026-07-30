import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connector_catalog.dart';
import 'connector_link_controller.dart';
import 'connectors_controller.dart';

/// Re-read every source the Connectors screen is built from.
///
/// The screen joins three independent reads — the agent's configured MCP
/// servers, the gateway's catalog, and this machine's stored tokens — and every
/// mutation on the screen changes at least two of them. Disconnecting, for
/// instance, deletes a token, drops a config entry, *and* flips the connector's
/// `status` at the gateway.
///
/// Which is why this is one function rather than a line in each controller.
/// Refresh-after-write was open-coded per mutation before, and each new source
/// had to be remembered at every call site; it wasn't, twice — a disconnect that
/// left the row reading Connected, and a toolbar Refresh that re-read a third of
/// the screen and looked broken. A single definition of "the data changed" can
/// be wrong once, not once per caller.
///
/// Cheap by design: these are file reads and one HTTP GET, and the alternative
/// — each caller invalidating only what it believes it touched — is what
/// produced the stale rows. Correct and slightly wasteful beats surgical and
/// wrong.
/// Set [isServersController] when the caller *is* `McpServersController`.
///
/// Riverpod asserts on a provider invalidating itself, so that one caller has to
/// reach its own state through `invalidateSelf` instead. The exception lives
/// here rather than in the caller, so the list of sources stays in one place.
void refreshConnectors(Ref ref, {bool isServersController = false}) {
  if (!isServersController) ref.invalidate(mcpServersProvider);
  ref.invalidate(connectorCatalogProvider);
  ref.invalidate(connectorTokensProvider);
}

/// The [WidgetRef] form, for the toolbar's Refresh button.
///
/// Riverpod keeps `Ref` and `WidgetRef` as separate types, so the one function
/// can't serve both. The body stays here beside its twin, where a source added
/// to one is impossible to miss in the other.
void refreshConnectorsFromWidget(WidgetRef ref) {
  ref.invalidate(mcpServersProvider);
  ref.invalidate(connectorCatalogProvider);
  ref.invalidate(connectorTokensProvider);
}
