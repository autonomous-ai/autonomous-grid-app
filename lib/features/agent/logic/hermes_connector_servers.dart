import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/connector_token.dart';

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
class HermesConnectorServers {
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
  static const String marker = '_grid';

  /// Make `mcp_servers` match [tokens]: an entry for every connector that has a
  /// usable MCP entry, and no leftovers from ones that no longer do.
  ///
  /// Idempotent — running it twice with the same tokens rewrites the same
  /// bytes. Callers treat it as the thing to do whenever anything changed, so
  /// it has to be cheap to over-call.
  Future<void> project(List<ConnectorToken> tokens) async {
    final wanted = <String, ConnectorToken>{
      for (final token in tokens)
        if (token.mcpEntry != null) token.connector: token,
    };

    await _edit((editor) {
      final existing = editor.parseAt([
        'mcp_servers',
      ], orElse: () => wrapAsYamlNode(null)).value;

      // Drop ours that are no longer wanted — a disconnected connector has to
      // stop working, and an entry left behind keeps the agent calling it until
      // the token expires. Anything without the marker is left exactly as-is.
      if (existing is Map) {
        for (final key in existing.keys.toList()) {
          final name = key is String ? key : key.toString();
          if (wanted.containsKey(name)) continue;
          if (!_isOurs(existing[key])) continue;
          editor.remove(['mcp_servers', name]);
        }
      }

      if (wanted.isEmpty) return;
      _ensureMap(editor, ['mcp_servers']);
      for (final entry in wanted.entries) {
        // Refuse to overwrite a server this app didn't write. A user with a
        // hand-configured `notion` would otherwise have it silently replaced
        // the moment they signed into the catalog's Notion.
        final current = existing is Map ? existing[entry.key] : null;
        if (current != null && !_isOurs(current)) continue;
        editor.update(['mcp_servers', entry.key], _entryFor(entry.value));
      }
    });
  }

  /// The YAML value for one connector.
  ///
  /// `auth` is deliberately absent. Hermes treats `auth: oauth` as "run the
  /// OAuth flow yourself", which would send it looking for the client
  /// credentials that live at the gateway and never on this machine — and,
  /// failing to find them, open a browser. The headers carry the credential
  /// already, so the entry is a plain authenticated HTTP server as far as
  /// Hermes is concerned.
  Map<String, Object?> _entryFor(ConnectorToken token) {
    final mcp = token.mcpEntry!;
    return {
      'url': mcp.url,
      if (mcp.headers.isNotEmpty) 'headers': mcp.headers,
      marker: {
        'connector': token.connector,
        if (mcp.expiresAt != null)
          'expires_at': mcp.expiresAt!.millisecondsSinceEpoch ~/ 1000,
        'refresh': mcp.canRefresh,
      },
    };
  }

  /// True when this app wrote the entry — the only ones it may touch.
  ///
  /// A `YamlMap` is already a `Map`, so this reads both the parsed nodes and
  /// the plain maps written back during an edit.
  bool _isOurs(Object? entry) => entry is Map && entry.containsKey(marker);

  /// The connectors this app currently owns entries for. Used to tell a stale
  /// token file from one Hermes obtained through its own OAuth flow.
  Future<Set<String>> owned() async {
    final text = await _read();
    if (text == null) return const {};
    try {
      final servers = YamlEditor(
        text,
      ).parseAt(['mcp_servers'], orElse: () => wrapAsYamlNode(null)).value;
      if (servers is! Map) return const {};
      return {
        for (final key in servers.keys)
          if (_isOurs(servers[key])) key.toString(),
      };
    } on Object {
      return const {};
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
