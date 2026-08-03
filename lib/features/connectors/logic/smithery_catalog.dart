import 'connector_catalog.dart';
import 'smithery_server.dart';

/// Renders a directory listing as a catalog row.
///
/// **Why a conversion rather than a second kind of row.** Everything downstream
/// of this — the card, the Connect button, the sign-in, the token store, the
/// projection into three agents — already works on `ConnectorCatalogEntry`, and
/// a Smithery server genuinely is one of those: a name, a mark, and an address
/// that signs itself in. Teaching the screen about a second row type would mean
/// a second Connect path, and the second path is the one that rots.
///
/// [ConnectorCatalogEntry.authMethod] is [ConnectorAuthMethod.dcr] because that
/// is what these servers are: measured 2026-08-03, 11 of 12 sampled Smithery
/// servers answer their 401 with a `registration_endpoint`, all of them under
/// one authorization server (`auth.smithery.ai/<name>/register`, PKCE S256,
/// refresh tokens). The claim is a *starting point* either way — `connectCatalog`
/// probes before it believes it, and a server that cannot self-register falls
/// through to the manual form, exactly as a typed URL does.
ConnectorCatalogEntry smitheryCatalogEntry(
  SmitheryServer server,
) => ConnectorCatalogEntry(
  // The registry's id is not used: `code` is the join key against configured
  // MCP servers, and it has to be the same string the projection will write.
  id: server.qualifiedName,
  // Hyphenated, because this becomes a key in `config.yaml` and a `/` in a
  // YAML key invites quoting bugs. `SmitheryServer.suggestedName` owns that
  // decision; repeating the `replaceAll` here would be a second place for it
  // to drift.
  code: server.suggestedName,
  label: server.displayName,
  description: server.description,
  imageUrl: server.iconUrl,
  mcpUrl: server.mcpUrl,
  authMethod: ConnectorAuthMethod.dcr,
  // Deliberately left at their defaults, and each for the same reason:
  // `installed`, `linkedAtServer`, `accountName` and `canRefresh` all
  // describe something *the gateway* knows about a user's account, and the
  // gateway has never heard of these rows. `linkedAtServer: true` here would
  // put "connected to your account, but not on this computer" under a row no
  // account was ever linked to.
  //
  // `mcpReady` is false for the same honesty: it means the gateway has tools
  // wired up behind the connector, which is not a claim anyone has made
  // about a directory entry. Nothing gates the Connect button on it
  // (`canConnectFromApp` reads `isSelfServe`), so leaving it false costs the
  // row nothing.
);

/// [servers] as catalog rows, dropping any that could not be connected anyway.
///
/// The filter is belt-and-braces: `SmitheryPage.fromJson` already drops
/// non-connectable rows, so this only catches a server built by hand in a test.
List<ConnectorCatalogEntry> smitheryCatalogEntries(
  Iterable<SmitheryServer> servers,
) => [
  for (final server in servers)
    if (server.connectable) smitheryCatalogEntry(server),
];
