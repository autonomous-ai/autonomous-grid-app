import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import 'mcp_server.dart';

/// Reads and writes the MCP servers in `~/.hermes/config.yaml`.
///
/// MCP servers are configured under `mcp_servers:` in Hermes's own config —
/// there is no CLI flag for it — so, like the task-power editor, the app edits
/// that file directly with a YAML editor that leaves everything else untouched
/// and backs the file up to `<file>.bak` before each write.
///
/// The app and Hermes share this file, so reads are lenient (a hand-added or
/// half-written server is skipped, see [parseMcpServers]) and writes are
/// surgical (only the one server's key changes).
class HermesMcpConfig {
  HermesMcpConfig({String? home})
    : _home = home ?? Platform.environment['HOME'] ?? '';

  final String _home;

  File get _config => File('$_home/.hermes/config.yaml');

  /// The configured servers, or an empty list when the file or the section is
  /// missing. Never throws — a broken config reads as "no servers".
  Future<List<McpServer>> read() async {
    final text = await _read();
    if (text == null) return const [];
    try {
      final node = YamlEditor(
        text,
      ).parseAt(['mcp_servers'], orElse: () => wrapAsYamlNode(null)).value;
      return parseMcpServers(node);
    } on Object {
      return const [];
    }
  }

  /// Add or replace [server], keyed by its name. Merged into whatever else is in
  /// the config, with a `.bak` written first.
  Future<void> upsert(McpServer server) async {
    await _edit((editor) {
      _ensureMap(editor, ['mcp_servers']);
      editor.update(['mcp_servers', server.name], server.toConfigValue());
    });
  }

  /// Remove the server named [name]; a no-op when it isn't there.
  Future<void> remove(String name) async {
    await _edit((editor) {
      final servers = editor.parseAt([
        'mcp_servers',
      ], orElse: () => wrapAsYamlNode(null)).value;
      if (servers is! Map || !servers.containsKey(name)) return;
      editor.remove(['mcp_servers', name]);
    });
  }

  Future<void> _edit(void Function(YamlEditor) change) async {
    final text = await _read() ?? '';
    final editor = YamlEditor(text.trim().isEmpty ? '{}\n' : text);
    change(editor);
    await _config.parent.create(recursive: true);
    if (await _config.exists()) await _config.copy('${_config.path}.bak');
    await _config.writeAsString('${editor.toString().trimRight()}\n');
  }

  Future<String?> _read() async {
    if (!await _config.exists()) return null;
    final text = await _config.readAsString();
    return text.trim().isEmpty ? null : text;
  }

  /// Make sure [path] holds a map before writing a child key into it — a config
  /// that never had a `mcp_servers:` section starts as null.
  void _ensureMap(YamlEditor editor, List<String> path) {
    final existing = editor
        .parseAt(path, orElse: () => wrapAsYamlNode(null))
        .value;
    if (existing is Map) return;
    editor.update(path, <String, Object?>{});
  }
}
