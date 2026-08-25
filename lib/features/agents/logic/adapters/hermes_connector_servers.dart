import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import '../../../../core/agent_homes.dart';
import '../../../../core/grid_paths.dart';
import '../connector_runtime.dart';
import '../connector_token.dart';
import '../marked_map_projection.dart';
import '../rest_entry.dart';

/// Writes the `mcp_servers` entries for connectors the app manages.
///
/// A token on disk is not enough to make a connector work. Hermes reads
/// `~/.hermes/mcp-tokens/<name>.json` only for a server that `config.yaml`
/// tells it about — with no entry, the token file is an orphan and the agent
/// never learns the connector exists. This class writes the missing half.
///
/// What goes in the entry is the gateway's own `mcp_entry`, rendered per the
/// provider's header convention (`Authorization: Bearer` for most, `X-Figma-
/// Token` for Figma). Storing it verbatim means adding a provider with an
/// unusual header is a change at the backend and none here.
///
/// **The `_grid` marker is the safety rail.** `~/.hermes/config.yaml` is shared
/// with the user and with Hermes itself, and it holds MCP servers nobody here
/// put there. Every entry this class writes carries `_grid`, and it will only
/// ever modify or delete an entry that has one. An entry without the marker is
/// somebody's hand-written config; removing it would lose work that cannot be
/// recovered from anywhere.
///
/// Only the four members below are Hermes-specific — which file, how YAML is
/// read and written, what an entry looks like, and that the marker fits inside
/// it. The policy that made this class worth getting right (delete by name, the
/// marker guard, the refuse-to-overwrite guard) lives in [MarkedMapProjection]
/// so the next agent's adapter inherits it rather than re-deriving it.
class HermesConnectorServers extends MarkedMapProjection {
  HermesConnectorServers({String? home, this.bridgeEndpointFor}) : _home = home;

  final String? _home;

  /// The loopback MCP URL serving a REST-backed connector, when the bridge is
  /// up. Null before it binds, and for a build with no bridge at all — in which
  /// case those connectors are simply not projected, and the entries already in
  /// the config are left alone.
  final String? Function(String connector)? bridgeEndpointFor;

  /// Hermes resolves its home from `HERMES_HOME` before `~/.hermes`. Follow the
  /// same override, or a user running a second profile gets servers written
  /// where their agent will never read them.
  String get _hermesHome {
    final override = _home ?? Platform.environment['HERMES_HOME'];
    if (override != null && override.isNotEmpty) return override;
    // Grid's own profile, not the user's root — the same home every `hermes`
    // the app spawns is given (see HostEnvironment.hermesEnvironment).
    return AgentHomes.hermesProfile(GridPaths.userHome);
  }

  File get configFile => File('$_hermesHome/config.yaml');

  /// The key that marks an entry as written by this app.
  static const String markerKey = '_grid';

  /// Hermes keeps unknown keys through its own edits (`hermes_cli/mcp_config.py`
  /// upserts per key), so ownership rides inside the entry.
  @override
  final MarkerStrategy marker = const InEntryMarker(markerKey);

  @override
  Future<Map<String, Object?>> readEntries() async {
    final text = await _read();
    if (text == null) return const {};
    try {
      final servers = YamlEditor(
        text,
      ).parseAt(['mcp_servers'], orElse: () => wrapAsYamlNode(null)).value;
      if (servers is! Map) return const {};
      // Keys come back as YAML scalars; the projection speaks in names.
      return {for (final key in servers.keys) key.toString(): servers[key]};
    } on Object {
      return const {};
    }
  }

  @override
  Future<void> applyEntries({
    required Map<String, Object?> upsert,
    required Set<String> remove,
  }) => _edit((editor) {
    // Safe without an `mcp_servers` guard: the base only names an entry it saw
    // in [readEntries], which cannot have found one unless the map exists.
    for (final name in remove) {
      editor.remove(['mcp_servers', name]);
    }
    if (upsert.isEmpty) return;
    _ensureMap(editor, ['mcp_servers']);
    for (final entry in upsert.entries) {
      editor.update(['mcp_servers', entry.key], entry.value);
    }
  });

  /// The YAML value for one connector — a URL, and headers when there are any.
  ///
  /// `auth` is deliberately absent. Hermes treats `auth: oauth` as "run the
  /// OAuth flow yourself", which would send it looking for the client
  /// credentials that live at the gateway and never on this machine — and,
  /// failing to find them, open a browser. Whatever credential is needed is
  /// already attached, so the entry is a plain authenticated HTTP server as far
  /// as Hermes is concerned.
  ///
  /// **Both transports land on the same shape.**
  ///
  /// That is the payoff of putting the bridge behind MCP: Hermes cannot tell a
  /// connector the gateway hosts from one this app is translating out of a REST
  /// API, and neither can the projection. A REST entry carries no headers at
  /// all, because the credential never leaves the app — the bridge attaches it
  /// per request, from the master store, at the moment of the call.
  @override
  Map<String, Object?>? entryFor(
    ConnectorToken token,
    Map<String, Object?>? markerValue,
  ) {
    switch (effectiveTransport(token)) {
      case ConnectorTransport.mcp:
        final mcp = token.mcpEntry!;
        if (mcp.headers.isEmpty) {
          return {'url': mcp.url, markerKey: ?markerValue};
        }
        // **This is D17 being repaid.** This branch used to write
        // `headers: {Authorization: Bearer …}` straight into `config.yaml` —
        // a live credential in a file that is shared, backed up to
        // `config.yaml.bak`, and read by a human. It was the one place in the
        // app that broke rule 5, recorded as a debt rather than a drift, and
        // the reason Codex and Claude Code refused to copy this shape.
        //
        // The bridge now forwards MCP as well as REST, so the credential stays
        // in the master store and Hermes is handed the same loopback address
        // every other agent gets. All three adapters render the identical
        // entry, which is the second win: the shape that could be copied wrongly
        // no longer exists.
        //
        // The cost, stated plainly: a connector that used to work with Grid
        // closed now needs Grid running, exactly like every REST connector
        // already does. That is the price of the credential not living in a
        // config file, and it was accepted deliberately.
        final endpoint = bridgeEndpointFor?.call(token.connector);
        if (endpoint == null) return null;
        return {'url': endpoint, markerKey: ?markerValue};
      case ConnectorTransport.rest:
        final endpoint = bridgeEndpointFor?.call(token.connector);
        // Skip rather than guess a port: see MarkedMapProjection.entryFor.
        if (endpoint == null) return null;
        return {'url': endpoint, markerKey: ?markerValue};
      case ConnectorTransport.none:
        return null;
    }
  }

  Future<void> _edit(void Function(YamlEditor) change) async {
    final text = await _read() ?? '';
    final editor = YamlEditor(text.trim().isEmpty ? '{}\n' : text);
    change(editor);
    await configFile.parent.create(recursive: true);
    // A backup before every write, exactly as `HermesMcpConfig` does: this file
    // is the user's, and a bad edit that loses their model or provider settings
    // is not recoverable from anywhere else.
    if (await configFile.exists()) {
      await configFile.copy('${configFile.path}.bak');
    }
    await configFile.writeAsString('${editor.toString().trimRight()}\n');
  }

  Future<String?> _read() async {
    if (!await configFile.exists()) return null;
    final text = await configFile.readAsString();
    return text.trim().isEmpty ? null : text;
  }

  /// Make sure [path] holds a map before writing a child into it — a config
  /// where the key is absent, or present but null, would otherwise throw.
  void _ensureMap(YamlEditor editor, List<Object> path) {
    final node = editor.parseAt(path, orElse: () => wrapAsYamlNode(null)).value;
    if (node is Map) return;
    editor.update(path, <String, Object?>{});
  }
}
