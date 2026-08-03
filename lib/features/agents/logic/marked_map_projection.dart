import 'dart:convert';
import 'dart:io';

import 'connector_runtime.dart';
import 'connector_token.dart';
import 'rest_entry.dart';

/// How one agent records that a configured MCP server belongs to Grid.
///
/// Two shapes exist because the config formats disagree about extra keys.
/// Hermes and Claude Code preserve an unknown key inside an entry, so ownership
/// travels with the thing it describes ([InEntryMarker]). Codex does not:
/// `codex mcp add`/`remove` re-serializes the parsed struct, so an unknown key
/// reads back fine and is then silently dropped by the next unrelated edit —
/// that agent needs its record kept beside the store instead, in
/// `~/.grid/connectors/projections/codex.json`, holding names and never a token.
///
/// The distinction is not cosmetic. An entry that loses its marker stops being
/// recognised by `ConnectorsController._projectManual`, which then adopts it
/// into the manual store — copying a credential into a second file and
/// resurrecting a connector the user disconnected.
abstract interface class MarkerStrategy {
  /// The marker to embed in the entry itself, or null when this agent keeps its
  /// record out of band.
  Map<String, Object?>? markerFor(ConnectorToken token);

  /// The entry names this app owns, given everything currently configured.
  ///
  /// Takes the configured entries rather than reading them itself so an
  /// out-of-band record can be intersected with reality: a name in the sidecar
  /// whose entry the user deleted by hand is not owned, it is gone.
  Future<Set<String>> owned(Map<String, Object?> entries);

  /// Called after a successful write, so a record kept outside the entries can
  /// follow them. A no-op for a marker that lives in the entry.
  Future<void> record({
    required Set<String> added,
    required Set<String> removed,
  });
}

/// Ownership written into the entry itself, under [key].
class InEntryMarker implements MarkerStrategy {
  const InEntryMarker(this.key);

  /// The key added to every entry this app writes. `_grid` for Hermes.
  final String key;

  /// The entry's marker never depends on *how* the connector is reached.
  ///
  /// It used to read straight off `mcpEntry`, which was fine while that was the
  /// only way in and a null-pointer the moment a REST-backed connector arrived.
  /// The gateway's entry is still preferred where it has an opinion, so the
  /// bytes written for existing connectors do not move.
  @override
  Map<String, Object?> markerFor(ConnectorToken token) {
    final mcp = token.mcpEntry;
    final expiry = mcp?.expiresAt ?? token.expiresAt;
    return {
      'connector': token.connector,
      if (expiry != null) 'expires_at': expiry.millisecondsSinceEpoch ~/ 1000,
      'refresh': mcp?.canRefresh ?? token.canBeRefreshed,
    };
  }

  /// A parsed YAML or JSON node is already a `Map`, so this reads both the nodes
  /// coming out of the config and the plain maps written back during an edit.
  @override
  Future<Set<String>> owned(Map<String, Object?> entries) async => {
    for (final entry in entries.entries)
      if (entry.value is Map && (entry.value as Map).containsKey(key))
        entry.key,
  };

  @override
  Future<void> record({
    required Set<String> added,
    required Set<String> removed,
  }) async {}
}

/// Ownership recorded in a file beside the store, for an agent that will not
/// keep an unknown key.
///
/// **Measured, not assumed** (2026-08-03, `codex-cli 0.146.0-alpha.3.1`): a
/// `config.toml` holding
///
/// ```toml
/// [mcp_servers.marked]
/// url = "http://127.0.0.1:61755/c/gmail/mcp"
///
/// [mcp_servers.marked._grid]
/// connector = "gmail"
/// ```
///
/// loses the whole `_grid` table the next time `codex mcp add` runs for a
/// **different** server. Nothing warns; the entry simply comes back without it.
/// That is the exact failure [MarkerStrategy] was split to avoid: an entry that
/// loses its marker stops being recognised as ours, and
/// `ConnectorsController._projectManual` then adopts it into the manual store —
/// copying a credential into a second file and resurrecting a connector the user
/// disconnected.
///
/// So the record lives at [file] and holds **names only, never a token**. The
/// names are worthless on their own; the credential stays in the master store.
class SidecarMarker implements MarkerStrategy {
  SidecarMarker({required this.file});

  /// Where the owned names are kept — `~/.grid/connectors/projections/<agent>.json`.
  final File file;

  /// Nothing goes in the entry. The agent would drop it anyway, and a marker
  /// that is silently unreliable is worse than none: it reads as ownership right
  /// up until the edit that erases it.
  @override
  Map<String, Object?>? markerFor(ConnectorToken token) => null;

  /// The recorded names, **intersected with what is actually configured**.
  ///
  /// The intersection is the point. A sidecar can outlive the thing it
  /// describes: a user who deletes an entry by hand, or runs `codex mcp remove`,
  /// leaves a name behind here. Claiming to own an entry that no longer exists
  /// would let the next projection "remove" a name that is already gone and,
  /// worse, let a *new* server the user later creates under the same name be
  /// treated as ours and overwritten.
  @override
  Future<Set<String>> owned(Map<String, Object?> entries) async {
    final recorded = await _read();
    return {
      for (final name in recorded)
        if (entries.containsKey(name)) name,
    };
  }

  @override
  Future<void> record({
    required Set<String> added,
    required Set<String> removed,
  }) async {
    final next = (await _read())..addAll(added);
    next.removeAll(removed);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'connectors': next.toList()..sort()}),
        flush: true,
      );
    } on Object {
      // Losing this file costs ownership of the entries it named: they stay in
      // the config and stop being recognised as ours. That is the safe
      // direction — the app under-claims rather than over-claims — so it is not
      // worth failing a projection that already succeeded.
    }
  }

  Future<Set<String>> _read() async {
    try {
      if (!await file.exists()) return <String>{};
      final decoded = jsonDecode(await file.readAsString());
      final list = decoded is Map ? decoded['connectors'] : null;
      if (list is! List) return <String>{};
      return {
        for (final name in list)
          if (name is String && name.isNotEmpty) name,
      };
    } on Object {
      // Unreadable reads as "we own nothing", which leaves every entry alone.
      return <String>{};
    }
  }
}

/// The projection policy every agent shares, with rendering left to each.
///
/// The split is deliberate and load-bearing: the three rules below each cost a
/// bug, and copying them into a second, third and fourth adapter is how they
/// drift back. What differs per agent is only *rendering* — which file, which
/// format, which key names, and where a marker may live.
///
/// **1. Deletion is by name, never by subtraction.** Only [project]'s `removing`
/// deletes. This method used to drop every marked entry absent from `tokens`,
/// which reads as "make the config match the store" and is wrong in one
/// specific, destructive way: `tokens` is the *whole master store*, so an empty
/// store means "delete everything". On 2026-07-30 a single expired `asana` token
/// was erased by a failed refresh, the store went empty, and that wiped two
/// unrelated working connectors — neither of which had anything to do with the
/// failure. A projection cannot tell "this connector is gone" from "the store
/// could not be read", so it must not guess.
///
/// **2. An entry without the marker is the user's.** It is never removed and
/// never overwritten, even when asked directly for it by name.
///
/// **3. Writing nothing writes nothing.** A sweep with no upserts and no
/// removals must not touch the file at all — these config files belong to the
/// user, and a fan-out across several agents would otherwise churn every one of
/// them on every refresh.
abstract class MarkedMapProjection {
  /// How ownership is recorded for this agent.
  MarkerStrategy get marker;

  /// Every MCP server currently configured, by name. Values stay opaque —
  /// only [MarkerStrategy] and [entryFor] know their shape.
  Future<Map<String, Object?>> readEntries();

  /// Apply one batch. Implementations should edit surgically rather than
  /// rewriting the document: these files hold the user's own settings beside
  /// ours.
  Future<void> applyEntries({
    required Map<String, Object?> upsert,
    required Set<String> remove,
  });

  /// The config value for one connector, in this agent's format, or **null when
  /// this agent cannot express it right now**.
  ///
  /// Null is not an error and not a permanent verdict — the common case is a
  /// REST-backed connector asked for before [ConnectorBridge] has bound its
  /// port. Skipping leaves whatever is already in the config untouched and lets
  /// the next projection (launch reconcile, refresh sweep, connect) write it,
  /// which is strictly better than either writing a URL that resolves to
  /// nothing or removing an entry that was working.
  ///
  /// [markerValue] is null when [marker] keeps its record out of band, in which
  /// case nothing about ownership belongs in the entry.
  Map<String, Object?>? entryFor(
    ConnectorToken token,
    Map<String, Object?>? markerValue,
  );

  /// The connectors this app currently owns entries for.
  Future<Set<String>> owned() async => marker.owned(await readEntries());

  /// Write an entry for every connector in [tokens] that has a usable MCP
  /// entry, and remove the ones named in [removing].
  ///
  /// Idempotent — running it twice with the same tokens rewrites the same
  /// bytes. Callers treat it as the thing to do whenever anything changed, so
  /// it has to be cheap to over-call.
  Future<void> project(
    List<ConnectorToken> tokens, {
    Set<String> removing = const {},
  }) async {
    // "Reachable at all", not "has an mcp_entry". A connector the gateway
    // describes only as REST is just as real to the agent once the bridge is
    // serving it, and gating on the entry alone is what left Gmail linked in
    // the app and absent from Hermes.
    final wanted = <String, ConnectorToken>{
      for (final token in tokens)
        if (effectiveTransport(token) != ConnectorTransport.none)
          token.connector: token,
    };

    final existing = await readEntries();
    final ours = await marker.owned(existing);

    // Only the named ones, and only if we wrote them — a disconnected connector
    // has to stop working, and an entry left behind keeps the agent calling it
    // until the token expires.
    final remove = <String>{
      for (final name in removing)
        if (!wanted.containsKey(name) &&
            existing.containsKey(name) &&
            ours.contains(name))
          name,
    };

    final upsert = <String, Object?>{};
    for (final entry in wanted.entries) {
      // Refuse to overwrite a server this app didn't write. A user with a
      // hand-configured `notion` would otherwise have it silently replaced the
      // moment they signed into the catalog's Notion.
      if (existing.containsKey(entry.key) && !ours.contains(entry.key)) {
        continue;
      }
      final value = entryFor(entry.value, marker.markerFor(entry.value));
      if (value == null) continue;
      upsert[entry.key] = value;
    }

    if (upsert.isEmpty && remove.isEmpty) return;
    await applyEntries(upsert: upsert, remove: remove);
    await marker.record(added: upsert.keys.toSet(), removed: remove);
  }
}
