import 'composio_toolkit.dart';
import 'connector_catalog.dart';
// `flattenDescription` still lives with the directory it was written for. It is
// not Smithery-specific — it turns any author's markdown into one line — and
// duplicating it here would be two copies to fix. When the Smithery source is
// finally removed, this function moves rather than dies.
import 'smithery_catalog.dart';

/// Renders a Composio toolkit as a catalog row.
///
/// The same job `smitheryCatalogEntry` does, and deliberately the same shape of
/// job: everything downstream — the card, the Connect button, the token store,
/// the projection into three agents — already works on `ConnectorCatalogEntry`,
/// so a new directory is a new *source* of those rows and not a new kind of row.
///
/// **[ConnectorAuthMethod.app], and that one field is the whole migration.**
/// Smithery rows were `dcr`: the app registered itself with each server and held
/// the credential. Composio brokers instead — it owns the OAuth app, runs the
/// consent flow and keeps the token — which is exactly what `app` means here and
/// exactly what the gateway path already does. So `connectCatalog` sees
/// `isSelfServe == false`, routes to `connect()`, and the existing
/// start → browser → poll → store flow runs unchanged. No new Connect path was
/// written for this, which is the point: the second path is the one that rots.
ConnectorCatalogEntry composioCatalogEntry(
  ComposioToolkit toolkit,
) => ConnectorCatalogEntry(
  // Slug for both, unchanged. Smithery's `qualifiedName` carried a publisher
  // prefix that had to be rewritten before it could be a config key;
  // Composio's slug is already flat and stable, so `id` and `code` are the
  // same string and there is no derivation to drift.
  id: toolkit.slug,
  code: toolkit.slug,
  label: toolkit.name,
  description: flattenDescription(toolkit.description),
  imageUrl: toolkit.logoUrl,
  // **Empty on purpose.** A Composio MCP address is minted per user, server
  // side — `/v3/mcp/<server_id>?user_id=…` — and is delivered with the
  // credential when the sign-in completes, not published in the catalog.
  // Guessing one here would put an address in the row that no agent could
  // use, and `connectCatalog` only reads this for the self-serve path this
  // row deliberately is not on.
  mcpUrl: '',
  authMethod: ConnectorAuthMethod.app,
  // No number, rather than a misleading one. The star badge means "how many
  // people use this", which is the question worth asking on a registry
  // anyone can publish to. Composio's catalog is curated and its
  // `tools_count` measures breadth instead — showing 23 under a star would
  // answer a question nobody asked with a number that looks like a rating.
  // `_UseCount.of` draws nothing at zero, so the card simply omits it.
  useCount: 0,
  // Left false for the same reason the Smithery rows leave the account
  // fields alone: `installed`, `linkedAtServer` and `accountName` are things
  // the gateway knows about *this user's* account, and a catalog listing has
  // made no claim about any of them.
);

/// Every toolkit as a catalog row, in the order given.
///
/// **Order is preserved because the server chose it.** Composio sorts the whole
/// catalog by `sort_by`, so the sequence arriving here is already the answer to
/// the user's sort — unlike the previous directory, which had no sort parameter
/// and left the ordering to be redone locally over whatever rows had loaded.
List<ConnectorCatalogEntry> composioCatalogEntries(
  List<ComposioToolkit> toolkits,
) => [for (final toolkit in toolkits) composioCatalogEntry(toolkit)];
