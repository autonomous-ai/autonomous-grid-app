import 'dart:io';

import 'package:toml/toml.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/mcp_server.dart';

/// Reads and writes the MCP servers in `~/.codex/config.toml`.
///
/// The Codex counterpart to [HermesMcpConfig], with one structural difference
/// that shapes everything here: **there is no in-place TOML editor.** Hermes's
/// config is edited with `YamlEditor`, which rewrites one key and leaves the
/// bytes around it alone. TOML has no equivalent in this project's dependencies,
/// so a write means decoding the whole document and re-encoding it —
/// `ClientAppConfigurator._applyCodex` already accepts that same cost for the
/// provider block, and this follows it rather than inventing a second policy.
///
/// What that costs, stated plainly: **comments and key order do not survive a
/// write.** Every *setting* does. The `.bak` written before each write is the
/// safety net, and it is the same one `_applyCodex` relies on.
///
/// This file is shared with Codex itself and with the ChatGPT desktop app, which
/// writes its own servers into it. Both facts drive the merge rules below.
class CodexMcpConfig {
  // GridPaths.userHome for the same reason HermesMcpConfig uses it: two
  // resolutions of "home" in one feature eventually disagree.
  CodexMcpConfig({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  File get file => File('$_home/.codex/config.toml');

  /// The table every server lives under.
  static const String _section = 'mcp_servers';

  /// The keys this app understands and therefore owns on a write.
  ///
  /// Everything else in a server's table belongs to whoever put it there and is
  /// copied through untouched — see [upsert].
  static const Set<String> _ownedKeys = {
    'command',
    'args',
    'env',
    'url',
    'headers',
  };

  /// The configured servers, or an empty list when the file or the section is
  /// missing. Never throws — a broken config reads as "no servers", the same
  /// contract Hermes's reader offers.
  Future<List<McpServer>> read() async {
    try {
      final root = await _document();
      return parseMcpServers(root[_section]);
    } on Object {
      return const [];
    }
  }

  /// Add or replace [server], keyed by its name, with a `.bak` written first.
  ///
  /// **Only the transport keys are replaced.** A server's table can carry fields
  /// this app has no model for — `startup_timeout_sec`, `cwd`, and `enabled` are
  /// all present in a real config on this machine — and a read-into-[McpServer]
  /// round trip would drop them, because [McpServer] cannot hold what it cannot
  /// parse. Dropping `enabled = false` in particular would silently switch a
  /// server the user turned off back on.
  ///
  /// So the existing table is kept and only [_ownedKeys] are written over. The
  /// stale ones are cleared first: a server edited from stdio to HTTP must not
  /// keep a `command` beside its new `url`, which would read as both transports
  /// at once.
  Future<void> upsert(McpServer server) async {
    await _edit((root) {
      final servers = _childMap(root, _section);
      final existing = servers[server.name];
      final table = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      table.removeWhere((key, _) => _ownedKeys.contains(key));
      table.addAll(server.toConfigValue());
      servers[server.name] = table;
    });
  }

  /// Every `mcp_servers` entry, values left opaque.
  ///
  /// For the projection layer, which needs to see exactly what is on disk — the
  /// not-ours guard compares against raw entries, and a normalised view would
  /// report a server the app must not touch in the same shape as one it wrote.
  Future<Map<String, Object?>> readRaw() async {
    try {
      final servers = (await _document())[_section];
      if (servers is! Map) return const {};
      return {for (final key in servers.keys) '$key': servers[key]};
    } on Object {
      return const {};
    }
  }

  /// Apply a batch of upserts and removals in **one** read-modify-write.
  ///
  /// One pass, not a loop over [upsert] and [remove]: every write re-encodes the
  /// whole document and copies a `.bak`, so N calls would mean N rewrites of the
  /// user's file — and N chances for a crash to land between two of them.
  ///
  /// Each upsert merges like [upsert] does, preserving keys this app does not
  /// model.
  Future<void> applyEntries({
    required Map<String, Object?> upsert,
    required Set<String> remove,
  }) async {
    if (upsert.isEmpty && remove.isEmpty) return;
    await _edit((root) {
      final servers = _childMap(root, _section);
      for (final name in remove) {
        servers.remove(name);
      }
      for (final entry in upsert.entries) {
        final existing = servers[entry.key];
        final table = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        table.removeWhere((key, _) => _ownedKeys.contains(key));
        final value = entry.value;
        if (value is Map) {
          table.addAll({
            for (final field in value.entries) '${field.key}': field.value,
          });
        }
        servers[entry.key] = table;
      }
    });
  }

  /// Remove the server named [name]; a no-op when it isn't there.
  ///
  /// A no-op is not merely tolerated, it is required: without the guard, every
  /// call would rewrite the file — losing the comments in it — to change
  /// nothing.
  Future<void> remove(String name) async {
    final root = await _document();
    final servers = root[_section];
    if (servers is! Map || !servers.containsKey(name)) return;
    await _edit((root) {
      final servers = root[_section];
      if (servers is Map) servers.remove(name);
    });
  }

  /// Decode the file into a mutable tree, or an empty one when it isn't there.
  ///
  /// Deeply mutable: `TomlDocument.toMap()` hands back nested maps that are not
  /// safe to write into, so every level a caller edits is rebuilt on the way
  /// out. Doing that lazily in [_childMap] would leave the untouched branches
  /// aliased to the parsed document, which is fine for reading and a trap the
  /// first time someone edits one.
  Future<Map<String, dynamic>> _document() async {
    if (!await file.exists()) return <String, dynamic>{};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return <String, dynamic>{};
    return _deepCopy(TomlDocument.parse(text).toMap());
  }

  Future<void> _edit(void Function(Map<String, dynamic> root) change) async {
    final root = await _document();
    change(root);
    // An empty `mcp_servers` table is written as `[mcp_servers]` with nothing
    // under it, which is valid but reads as debris once the last server is
    // removed.
    final servers = root[_section];
    if (servers is Map && servers.isEmpty) root.remove(_section);

    await file.parent.create(recursive: true);
    if (await file.exists()) await file.copy('${file.path}.bak');
    await file.writeAsString(
      '${TomlDocument.fromMap(root).toString().trimRight()}\n',
    );
  }

  /// The child map at [key], created when absent.
  Map<String, dynamic> _childMap(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is Map<String, dynamic>) return existing;
    final created = <String, dynamic>{};
    parent[key] = created;
    return created;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    return {
      for (final entry in source.entries) entry.key: _copyValue(entry.value),
    };
  }

  static Object? _copyValue(Object? value) => switch (value) {
    Map() => <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _copyValue(entry.value),
    },
    List() => [for (final item in value) _copyValue(item)],
    _ => value,
  };
}
