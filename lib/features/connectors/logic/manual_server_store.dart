import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/mcp_server.dart';

/// The MCP servers the user configured by hand: `~/.grid/connectors/manual.json`,
/// mode `600`.
///
/// The twin of `ConnectorTokenStore`, and here for the same reason. A server
/// the user typed in belongs to *them*, not to whichever agent happened to be
/// selected at the time — so it lands here first, and each agent gets a
/// projection of it. Without this store, switching to another agent would empty
/// the list: the entries only ever existed inside one agent's config file.
///
/// The mode matters as much as it does for tokens. A manual entry routinely
/// carries a credential — an `Authorization` header, an API key in `env` — so
/// this file is exactly as sensitive as the OAuth store beside it.
class ManualServerStore {
  ManualServerStore({Directory? home}) : _home = home;

  /// Overridable so tests write into a temp dir and never touch the real
  /// `~/.grid`.
  final Directory? _home;

  Directory get directory => _home == null
      ? GridPaths.connectorsDir
      : Directory('${_home.path}/connectors');

  File get file => File('${directory.path}/manual.json');

  /// Every stored server, keyed by name.
  ///
  /// A missing file is an empty store, and so is one that won't parse: refusing
  /// to load would lock the user out of the screen that could fix it. The next
  /// successful [write] replaces whatever was there.
  Future<Map<String, McpServer>> read() async {
    if (!await file.exists()) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return {};
    }
    if (decoded is! Map<String, dynamic>) return {};
    // Reuses the config parser: the stored shape is deliberately the same one
    // Hermes reads, so a user can look at both files and see the same thing.
    return {for (final server in parseMcpServers(decoded)) server.name: server};
  }

  /// Replace the whole store. Callers go through [save] and [remove].
  Future<void> write(Map<String, McpServer> servers) async {
    await directory.create(recursive: true);
    final payload = {
      for (final entry in servers.entries)
        entry.key: entry.value.toConfigValue(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await _restrictPermissions();
  }

  /// Add or replace one server, leaving the others untouched.
  ///
  /// [previousName] renames: the old key is dropped in the same write, so a
  /// rename can't leave both names behind if the second write never happens.
  Future<void> save(McpServer server, {String? previousName}) async {
    final servers = await read();
    if (previousName != null && previousName != server.name) {
      servers.remove(previousName);
    }
    servers[server.name] = server;
    await write(servers);
  }

  Future<void> remove(String name) async {
    final servers = await read();
    if (servers.remove(name) == null) return;
    await write(servers);
  }

  /// Owner-only, best-effort — same reasoning as the token store: a weaker mode
  /// beats an abandoned write, and a manual entry can hold an API key.
  Future<void> _restrictPermissions() async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object {
      // Nothing to do and nothing to say.
    }
  }
}

/// Overridable so tests point at a temp home and never touch the real
/// `~/.grid/connectors`.
final manualServerStoreProvider = Provider<ManualServerStore>(
  (ref) => ManualServerStore(),
);
