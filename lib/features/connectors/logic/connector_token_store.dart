import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/connector_token.dart';

/// The master token store: `~/.grid/connectors/tokens.json`, mode `600`.
///
/// Agent-neutral and app-owned, the same way `~/.grid/skills` is. A connector
/// linked once has to work for *every* agent on this machine, not just the one
/// that happened to be selected — so the token lands here first and each agent
/// gets a projection of it (see `AgentMcpPlane.projectConnectorTokens`).
///
/// Unlike skills, a projection can't be a symlink: agents disagree about the
/// format a token is written in, so projecting is a transforming copy and every
/// change has to be re-projected. That is what makes this store necessary
/// rather than merely tidy — it is the only place that knows which connector a
/// token belongs to, when it expires, and what it should look like for whoever
/// asks next.
///
/// Why a file and not the OS credential store: the reader is an *agent
/// process*, not the app. A Keychain item can want an unlocked session or a
/// user prompt, and a background agent run would stall on it. Same exception
/// Hermes takes for its own `mcp-tokens/`, and Claude Code for
/// `~/.claude/.credentials.json`.
class ConnectorTokenStore {
  ConnectorTokenStore({Directory? home}) : _home = home;

  /// Overridable so tests write into a temp dir and never touch the real
  /// `~/.grid`.
  final Directory? _home;

  Directory get directory => _home == null
      ? GridPaths.connectorsDir
      : Directory('${_home.path}/connectors');

  File get file => File('${directory.path}/tokens.json');

  /// Every stored token, keyed by connector code.
  ///
  /// A missing file is an empty store, not an error — nothing has been linked
  /// yet. A file that won't parse also reads as empty: refusing to start
  /// because of one bad byte would lock the user out of the screen that could
  /// fix it. The next successful [write] replaces it.
  Future<Map<String, ConnectorToken>> read() async {
    if (!await file.exists()) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return {};
    }
    if (decoded is! Map<String, dynamic>) return {};

    final tokens = <String, ConnectorToken>{};
    for (final entry in decoded.entries) {
      final token = ConnectorToken.fromJson(entry.key, entry.value);
      if (token != null) tokens[entry.key] = token;
    }
    return tokens;
  }

  /// Replace the whole store. Callers read-modify-write through [save] and
  /// [remove] rather than calling this directly.
  Future<void> write(Map<String, ConnectorToken> tokens) async {
    await directory.create(recursive: true);
    final payload = {
      for (final entry in tokens.entries) entry.key: entry.value.toJson(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await _restrictPermissions();
  }

  /// Add or replace one connector's token, leaving the others untouched.
  Future<void> save(ConnectorToken token) async {
    final tokens = await read();
    tokens[token.connector] = token;
    await write(tokens);
  }

  Future<void> remove(String connector) async {
    final tokens = await read();
    if (tokens.remove(connector) == null) return;
    await write(tokens);
  }

  /// Make the file readable only by its owner.
  ///
  /// Best-effort by design: on Windows there is no `chmod` and the file's ACL
  /// already follows the user profile, and a sandbox may refuse to spawn a
  /// process at all. Failing the *write* over this would be worse than the
  /// weaker mode — the token is already on a single-user machine's home
  /// directory, and losing it means the connector silently stops working.
  Future<void> _restrictPermissions() async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object {
      // Nothing to do and nothing to say: see above.
    }
  }
}

/// Overridable so tests point at a temp home and never read or write the real
/// `~/.grid/connectors`.
final connectorTokenStoreProvider = Provider<ConnectorTokenStore>(
  (ref) => ConnectorTokenStore(),
);
