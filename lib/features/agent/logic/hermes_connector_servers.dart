import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/marked_map_projection.dart';

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
  HermesConnectorServers({String? home}) : _home = home;

  final String? _home;

  /// Hermes resolves its home from `HERMES_HOME` before `~/.hermes`. Follow the
  /// same override, or a user running a second profile gets servers written
  /// where their agent will never read them.
  String get _hermesHome {
    final override = _home ?? Platform.environment['HERMES_HOME'];
    if (override != null && override.isNotEmpty) return override;
    return '${GridPaths.userHome}/.hermes';
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

  /// The YAML value for one connector.
  ///
  /// `auth` is deliberately absent. Hermes treats `auth: oauth` as "run the
  /// OAuth flow yourself", which would send it looking for the client
  /// credentials that live at the gateway and never on this machine — and,
  /// failing to find them, open a browser. The headers carry the credential
  /// already, so the entry is a plain authenticated HTTP server as far as
  /// Hermes is concerned.
  @override
  Map<String, Object?> entryFor(
    ConnectorToken token,
    Map<String, Object?>? markerValue,
  ) {
    final mcp = token.mcpEntry!;
    return {
      'url': mcp.url,
      if (mcp.headers.isNotEmpty) 'headers': mcp.headers,
      markerKey: ?markerValue,
    };
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
