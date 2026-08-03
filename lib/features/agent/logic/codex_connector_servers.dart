import 'dart:io';

import '../../../core/grid_paths.dart';
import '../../agents/logic/connector_runtime.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/marked_map_projection.dart';
import '../../agents/logic/rest_entry.dart';
import 'codex_mcp_config.dart';

/// Projects the app's connectors into `~/.codex/config.toml`.
///
/// The Codex counterpart to [HermesConnectorServers], inheriting the same
/// policy from [MarkedMapProjection] — delete by name only, never touch an entry
/// we did not write, write nothing when there is nothing to write. Three things
/// differ, and each one is measured rather than assumed.
///
/// **1. Ownership lives beside the store, not in the entry.** Measured
/// 2026-08-03: a `[mcp_servers.x._grid]` table is silently dropped the next time
/// `codex mcp add` runs for an unrelated server. So [marker] is a
/// [SidecarMarker] over `~/.grid/connectors/projections/codex.json`, holding
/// names and never a credential.
///
/// **2. No headers, ever — for either transport.** Hermes writes the gateway's
/// `mcp_entry` headers into its config, which is D17: a live credential in a
/// hand-edited file. That debt is not going to be doubled here, on a file shared
/// with the ChatGPT desktop app. A connector whose only route needs a header is
/// therefore *not projected at all* rather than projected insecurely — see
/// [entryFor].
///
/// **3. Writes go through [CodexMcpConfig].** TOML has no in-place editor, so
/// every write re-encodes the document; that class already owns the merge rules
/// that keep unmodelled fields (`enabled`, `cwd`, `startup_timeout_sec`) intact.
class CodexConnectorServers extends MarkedMapProjection {
  CodexConnectorServers({
    CodexMcpConfig? config,
    String? home,
    this.bridgeEndpointFor,
  }) : _config = config ?? CodexMcpConfig(home: home),
       _home = home;

  final CodexMcpConfig _config;
  final String? _home;

  /// The loopback MCP URL serving a REST-backed connector, when the bridge is
  /// up. Null before it binds — those connectors are then skipped, and whatever
  /// is already in the config is left alone.
  final String? Function(String connector)? bridgeEndpointFor;

  File get configFile => _config.file;

  Directory get _projectionsDir => _home == null
      ? Directory('${GridPaths.connectorsDir.path}/projections')
      : Directory('$_home/connectors/projections');

  /// Names only. The credential stays in the master store, which is what makes
  /// this file safe to keep in plain sight.
  @override
  late final MarkerStrategy marker = SidecarMarker(
    file: File('${_projectionsDir.path}/codex.json'),
  );

  @override
  Future<Map<String, Object?>> readEntries() async {
    // Read the file rather than `codex mcp list --json`. The projection needs
    // the *raw* entries so `_ownedKeys`-style merging and the not-ours guard see
    // exactly what is on disk; the CLI's view is normalised and would report an
    // entry the app must not touch in the same shape as one it wrote.
    return _config.readRaw();
  }

  @override
  Future<void> applyEntries({
    required Map<String, Object?> upsert,
    required Set<String> remove,
  }) => _config.applyEntries(upsert: upsert, remove: remove);

  /// The TOML value for one connector: a URL and nothing else.
  ///
  /// **Both transports land on the same shape**, exactly as they do for Hermes,
  /// and for the same reason — the bridge is an MCP server, so Codex cannot tell
  /// a gateway-hosted connector from one the app is translating out of a REST
  /// API.
  ///
  /// Returns null — skip, do not write — in two cases:
  ///
  /// - **A REST connector before the bridge has bound.** Not an error and not
  ///   permanent; the next projection writes it. Skipping beats writing a URL
  ///   that resolves to nothing.
  /// - **An MCP connector whose entry carries headers.** Those headers *are* the
  ///   credential. Hermes writes them (D17); this does not. The connector is
  ///   reported as not-projectable rather than being written without the header,
  ///   which would produce the worst outcome available: an entry Codex loads,
  ///   calls, and gets 401 from — a row that looks connected and cannot work.
  @override
  Map<String, Object?>? entryFor(
    ConnectorToken token,
    Map<String, Object?>? markerValue,
  ) {
    // markerValue is always null here — SidecarMarker keeps nothing in the
    // entry — so there is deliberately no marker key written below.
    switch (effectiveTransport(token)) {
      case ConnectorTransport.mcp:
        final mcp = token.mcpEntry!;
        if (mcp.headers.isNotEmpty) return null;
        return {'url': mcp.url};
      case ConnectorTransport.rest:
        final endpoint = bridgeEndpointFor?.call(token.connector);
        if (endpoint == null) return null;
        return {'url': endpoint};
      case ConnectorTransport.none:
        return null;
    }
  }
}
