import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_extensions_registry.dart';
import '../../agents/logic/mcp_server.dart';
import 'connected_catalog_lookup.dart';
import 'connector.dart';
import 'connector_catalog.dart';
import '../../agents/logic/connector_token.dart';
import 'connector_link_controller.dart';
import 'connectors_refresh.dart';
import 'manual_server_store.dart';

/// The MCP servers configured for the selected agent, read straight from its
/// config so the screen and the agent can't disagree.
///
/// Every change writes through the agent's MCP plane and re-reads, so a server
/// that shows up here is one the agent will actually load on its next session.
final mcpServersProvider =
    AsyncNotifierProvider<McpServersController, List<McpServer>>(
      McpServersController.new,
    );

/// Every catalog entry this session has seen, kept past the page it arrived on.
///
/// **The catalog is a page of search results, not a directory.** It holds the
/// ~50 rows the registry last answered with, so a connector the user signed in
/// to yesterday is in it only while it happens to match the current query. The
/// moment it drops out, the row loses the entry it was joined to and with it its
/// label, its logo and its blurb: a signed-in Gmail rendered as a cloud glyph
/// named "Gmail" describing `http://127.0.0.1:61755/c/gmail/mcp` as soon as the
/// Finance pill was pressed (measured 2026-08-04).
///
/// Accumulating fixes that at the source. An entry is a *description of a
/// service* — Gmail's logo and blurb do not stop being true because the user
/// searched for something else — so once seen it is worth keeping for as long as
/// the screen is open.
///
/// Not persisted, and deliberately unbounded within a session: the registry caps
/// browsing at 500 rows, so this cannot grow past a few hundred small objects.
class SeenCatalogEntries extends Notifier<Map<String, ConnectorCatalogEntry>> {
  @override
  Map<String, ConnectorCatalogEntry> build() => const {};

  /// Fold a freshly fetched page in, newest description winning.
  ///
  /// Returns without notifying when the page adds nothing — this is called from
  /// inside a provider body, and a state write that changes nothing would
  /// rebuild every listener on every page fetch.
  void remember(List<ConnectorCatalogEntry> entries) {
    if (entries.isEmpty) return;
    final merged = {...state, for (final entry in entries) entry.code: entry};
    if (merged.length == state.length &&
        entries.every((e) => identical(state[e.code], e))) {
      return;
    }
    state = merged;
  }
}

final seenCatalogEntriesProvider =
    NotifierProvider<SeenCatalogEntries, Map<String, ConnectorCatalogEntry>>(
      SeenCatalogEntries.new,
    );

/// The full Connectors screen model: what's live in the agent's config joined
/// with what the catalog offers. The config side stays the only truth about
/// what the agent loads — the catalog only ever adds "available" rows.
final connectorsProvider = FutureProvider<List<Connector>>((ref) async {
  final servers = await ref.watch(mcpServersProvider.future);
  final page = await ref.watch(connectorCatalogProvider.future);
  // Remember this page, then join against everything seen so far. Order
  // matters: the fresh page has to be in the map before the join, or a
  // connector connected from the page currently on screen would miss its own
  // entry for one frame.
  ref.read(seenCatalogEntriesProvider.notifier).remember(page);
  final remembered = ref.read(seenCatalogEntriesProvider);
  // The page itself still governs which rows are *offered* — that is the
  // search result, and remembering must not put yesterday's search back on
  // screen. Entries are recalled only to describe rows that exist for another
  // reason: a configured server, or a credential held here.
  final configured = {for (final server in servers) server.name};
  // Entries fetched one by one for connectors the directory's pages have never
  // shown. See `MissingCatalogEntries`: the catalog is a page of search
  // results, so a connector that no longer ranks has no entry to join to at
  // all — measured 2026-08-04, three of eleven signed-in connectors on this
  // machine — and drew the generic glyph with no description under it.
  final fetched = ref.watch(missingCatalogEntriesProvider).value ?? const {};
  final catalog = <ConnectorCatalogEntry>[
    ...page,
    for (final entry in [...remembered.values, ...fetched.values])
      if (configured.contains(entry.code) &&
          !page.any((p) => p.code == entry.code))
        entry,
  ];
  // The third source: the credentials this machine actually holds. Optional —
  // an unreadable store leaves the rows reading from config and catalog alone,
  // which is the same screen this was before the gateway existed.
  final tokens =
      ref.watch(connectorTokensProvider).asData?.value ??
      const <String, ConnectorToken>{};

  // Ask for whatever is still unaccounted for, after this build rather than
  // during it: `fill` writes to a provider, and a provider that writes to
  // another while building throws. The fetch publishes and this rebuilds once
  // more with the entries in hand.
  final describable = {
    for (final entry in page) entry.code,
    ...remembered.keys,
    ...fetched.keys,
  };
  Future.microtask(
    () => ref
        .read(missingCatalogEntriesProvider.notifier)
        .fill(configured.union(tokens.keys.toSet()), describable),
  );
  // No merge left to do: `connectorCatalogProvider` *is* the public directory
  // now, and it is the only source of offers. The gateway's curated rows and the
  // bundled self-serve list were both removed (Tony, 2026-08-03).
  return buildConnectors(servers: servers, catalog: catalog, tokens: tokens);
});

class McpServersController extends AsyncNotifier<List<McpServer>> {
  @override
  Future<List<McpServer>> build() async {
    final tool = ref.watch(extensionAgentProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.mcp;
    if (plane == null) return const [];
    // Project the app's own record onto this agent before reading it back.
    // Selecting an agent for the first time — or switching to one — has to
    // carry the user's manual servers across, or they would appear to have
    // vanished with the agent that happened to be active when they were added.
    await _projectManual(plane);
    return plane.read();
  }

  /// Reconcile the app's store with the selected agent's config, both ways.
  ///
  /// **Store → agent** carries manual servers onto an agent that doesn't have
  /// them yet, which is what makes switching agents keep the user's work.
  ///
  /// **Agent → store** adopts servers the config has and the store doesn't.
  /// Those exist for two ordinary reasons: they were added before this store
  /// existed, or the user wrote them into `config.yaml` by hand. Either way
  /// they are manual servers, and leaving them unadopted means the next agent
  /// switch loses them — the exact problem the store was added to fix.
  ///
  /// Adoption skips anything carrying the `_grid` marker: those are projections
  /// of an OAuth connector, owned by the token store, and copying one here
  /// would duplicate a credential into a second file and resurrect the entry
  /// after a disconnect.
  ///
  /// Neither direction deletes. A server this app doesn't know about is
  /// somebody's configuration, not a stale row.
  Future<void> _projectManual(AgentMcpPlane plane) async {
    try {
      final store = ref.read(manualServerStoreProvider);
      final stored = await store.read();
      final configured = await plane.read();
      final existing = {for (final server in configured) server.name};

      // Asked of the config, not of the token store. Those disagree in a state
      // that really happens: disconnecting clears the token while a failed or
      // skipped re-projection can leave the config entry behind. Keyed on the
      // token store, such an orphan would be adopted as a manual server — the
      // user's disconnect quietly undone, credential header and all. The
      // config's own `_grid` marker says who wrote the entry, which is the
      // question actually being asked.
      final connectorEntries = await plane.connectorEntries();
      final adopted = {
        for (final server in configured)
          if (!stored.containsKey(server.name) &&
              !connectorEntries.contains(server.name))
            server.name: server,
      };
      if (adopted.isNotEmpty) {
        // Adoption is the one way an entry can enter the manual store without
        // the user typing it, so it is worth naming: a connector that appears
        // here after an OAuth sign-in means the `_grid` marker did not do its
        // job, and a credential is about to be copied into a second file.
        ref
            .read(appLogProvider)
            .info(
              'connectors',
              'Adopting ${adopted.length} unmanaged server(s) into the manual '
                  'store [${adopted.keys.join(', ')}] — connector-owned '
                  'entries were [${connectorEntries.join(', ')}]',
            );
        await store.write({...stored, ...adopted});
      }

      for (final server in stored.values) {
        if (existing.contains(server.name)) continue;
        await plane.upsert(server);
      }
    } on Object catch (error, stack) {
      // A reconcile failure leaves both sides as they were; the screen still
      // shows whatever the agent has. It is still *logged*: a silent catch here
      // meant a store that never filled looked identical to one that had
      // nothing to adopt, and cost an hour of looking in the wrong place.
      ref
          .read(appLogProvider)
          .failure(
            'connectors',
            'Reconciling the manual server store failed',
            error: error,
            stackTrace: stack,
          );
    }
  }

  AgentMcpPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.mcp;
  }

  /// Add or replace a server. Returns null on success, else a line to show —
  /// every caller is a button and needs something to say on failure.
  Future<String?> save(McpServer server) => _act(
    store: (store) => store.save(server),
    project: (plane) => plane.upsert(server),
  );

  /// Save [server] over the entry called [previousName] — the rename path,
  /// one call so no dialog open-codes the remove-then-save dance.
  Future<String?> rename(String previousName, McpServer server) => _act(
    store: (store) => store.save(server, previousName: previousName),
    project: (plane) => plane.rename(previousName, server),
  );

  Future<String?> remove(String name) => _act(
    store: (store) => store.remove(name),
    project: (plane) => plane.remove(name),
  );

  /// Write to the app's own store, then into the selected agent's config.
  ///
  /// The order is the whole point. `~/.grid/connectors/manual.json` is the
  /// record that outlives any one agent — the same role `tokens.json` plays for
  /// OAuth connectors — and the agent's config is a projection of it. Writing
  /// only the agent would put the user's work inside Hermes, where switching to
  /// Codex loses it.
  ///
  /// A projection failure is still reported, but the store keeps the change:
  /// the user asked for it, and the next projection will carry it over.
  ///
  /// Every exit re-reads the screen through [refreshConnectors] — including the
  /// failing ones. A write that half-succeeded is exactly when the screen is
  /// least trustworthy, and leaving it on the pre-write data there means the
  /// error message and the rows disagree about what happened.
  Future<String?> _act({
    required Future<void> Function(ManualServerStore) store,
    required Future<void> Function(AgentMcpPlane) project,
  }) async {
    try {
      try {
        await store(ref.read(manualServerStoreProvider));
      } on Object catch (error) {
        return "Couldn't save the connection: $error";
      }

      final plane = _plane;
      // Nothing to project onto. Not a failure — the record is safe, and it
      // will reach an agent that understands MCP as soon as one is selected.
      if (plane == null) return _noMcp;

      try {
        await project(plane);
      } on AgentExtensionException catch (error) {
        return error.message;
      } on Object catch (error) {
        return "Couldn't update the MCP servers: $error";
      }
      return null;
    } finally {
      refreshConnectors(ref, isServersController: true);
      // This provider's own re-read. `invalidateSelf` rather than `invalidate`
      // because Riverpod asserts on the latter — and going through `build`
      // rather than assigning state is what re-runs the reconcile, so a manual
      // server reaches the store on the same click that created it.
      ref.invalidateSelf();
    }
  }

  static const _noMcp = "This agent doesn't support MCP servers.";
}
