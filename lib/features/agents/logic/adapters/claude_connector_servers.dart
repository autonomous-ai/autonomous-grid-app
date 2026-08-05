import 'dart:io';

import '../connector_runtime.dart';
import '../connector_token.dart';
import '../marked_map_projection.dart';
import '../rest_entry.dart';
import 'claude_mcp_config.dart';

/// Projects the app's connectors into the user scope of `~/.claude.json`.
///
/// The third adapter, and the one that shows the split in [MarkedMapProjection]
/// paid for itself: the policy that cost the bugs — delete by name only, never
/// touch an entry we did not write, write nothing when there is nothing to
/// write — is inherited whole. Only rendering differs, and each difference below
/// was measured on 2026-08-03 against `claude 2.1.220`.
///
/// **1. Ownership rides in the entry, as it does for Hermes.** Measured: an
/// entry carrying a `_grid` key keeps it across `claude mcp add` for an
/// unrelated server, across `claude mcp remove`, and `claude mcp get` loads it
/// without complaint. That is the opposite of Codex, which drops an unknown
/// table on the next unrelated edit and therefore needed [SidecarMarker]. So
/// this uses [InEntryMarker] and there is no sidecar file to keep in step.
///
/// **2. The user scope, never the local one.** `claude mcp add` defaults to
/// `local`, filing the server under `projects[<cwd>].mcpServers`, where it is
/// visible in one directory only. A connector is the user's, not a folder's —
/// and a desktop app has no meaningful cwd to file it under anyway. See
/// [ClaudeMcpConfig].
///
/// **3. No headers, ever.** Hermes writes the gateway's `mcp_entry` headers into
/// its config, which is D17: a live credential sitting in a hand-edited file.
/// That debt is not being tripled. A connector whose only route needs a header
/// is not projected at all — see [entryFor].
class ClaudeConnectorServers extends MarkedMapProjection {
  ClaudeConnectorServers({
    ClaudeMcpConfig? config,
    String? home,
    this.bridgeEndpointFor,
  }) : _config = config ?? ClaudeMcpConfig(home: home);

  final ClaudeMcpConfig _config;

  /// The loopback MCP URL serving a REST-backed connector, when the bridge is
  /// up. Null before it binds — those connectors are then skipped, and whatever
  /// is already in the config is left alone.
  final String? Function(String connector)? bridgeEndpointFor;

  File get configFile => _config.file;

  /// The key that marks an entry as written by this app. The same spelling
  /// Hermes uses, because it means the same thing and a second name would only
  /// invite the two to drift.
  static const String markerKey = '_grid';

  @override
  final MarkerStrategy marker = const InEntryMarker(markerKey);

  @override
  Future<Map<String, Object?>> readEntries() => _config.readRaw();

  @override
  Future<void> applyEntries({
    required Map<String, Object?> upsert,
    required Set<String> remove,
  }) => _config.applyEntries(upsert: upsert, remove: remove);

  /// The JSON value for one connector: a typed URL, the marker, and nothing
  /// else.
  ///
  /// **Both transports land on the same shape**, exactly as they do for the
  /// other two agents and for the same reason — the bridge is an MCP server, so
  /// Claude Code cannot tell a gateway-hosted connector from one the app is
  /// translating out of a REST API.
  ///
  /// **An MCP connector needing a credential goes through the bridge too.** It
  /// used to be skipped: the header *is* the credential, and writing the entry
  /// without it produces the worst outcome available — an entry Claude Code
  /// loads, calls, and gets 401 from. That was the honest answer while the
  /// bridge only spoke REST; now that it forwards MCP as well, Claude Code can
  /// be given a loopback address and the app attaches the credential per
  /// request. Same rule as Codex, and for the same reason.
  ///
  /// A **header-less** MCP connector still points straight at its own server:
  /// nothing about it needs the app, and routing it through the bridge would
  /// only make it stop working whenever Grid is closed.
  ///
  /// Returns null — skip, do not write — when the bridge has not bound yet and
  /// the connector needs it. Not an error and not permanent; the next
  /// projection writes it.
  @override
  Map<String, Object?>? entryFor(
    ConnectorToken token,
    Map<String, Object?>? markerValue,
  ) {
    switch (effectiveTransport(token)) {
      case ConnectorTransport.mcp:
        final mcp = token.mcpEntry!;
        if (mcp.headers.isEmpty) {
          return {'type': 'http', 'url': mcp.url, markerKey: ?markerValue};
        }
        final endpoint = bridgeEndpointFor?.call(token.connector);
        if (endpoint == null) return null;
        return {'type': 'http', 'url': endpoint, markerKey: ?markerValue};
      case ConnectorTransport.rest:
        final endpoint = bridgeEndpointFor?.call(token.connector);
        if (endpoint == null) return null;
        return {'type': 'http', 'url': endpoint, markerKey: ?markerValue};
      case ConnectorTransport.none:
        return null;
    }
  }
}
