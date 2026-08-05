import 'dart:convert';
import 'dart:io';

import '../../../../core/grid_paths.dart';
import '../mcp_server.dart';

/// Reads and writes the user-scope MCP servers in `~/.claude.json`.
///
/// The Claude Code counterpart to [HermesMcpConfig] and [CodexMcpConfig]. Two
/// facts about this file shape everything below, and both were measured on
/// 2026-08-03 against `claude 2.1.220` rather than assumed.
///
/// **1. The file is Claude Code's entire state, not a settings file.** It holds
/// `projects` (14 of them on this machine), onboarding flags, cached feature
/// gates, history — 72 KB of things this app has no model for. So a write is a
/// read-modify-write of the decoded tree with only [_section] touched. Anything
/// resembling "encode what we know" would erase the user's whole Claude Code
/// install.
///
/// **2. Servers live under three scopes; this class owns exactly one.**
/// `claude mcp add` defaults to `local`, which files the server under
/// `projects[<cwd>].mcpServers` — visible in that one directory. `project`
/// writes `.mcp.json` into the repo, where it would be committed. The root
/// `mcpServers` key is the `user` scope, the only one that means "mine,
/// everywhere", which is what a connector is. See [_section].
///
/// Unlike Codex, JSON here is written by `JsonEncoder.withIndent('  ')`, which
/// is what Claude Code itself writes — so a round trip through this class is
/// byte-comparable rather than merely equivalent. There are no comments in JSON
/// to lose, which makes this the least destructive of the three writers.
class ClaudeMcpConfig {
  // GridPaths.userHome for the same reason the other two use it: two
  // resolutions of "home" in one feature eventually disagree.
  ClaudeMcpConfig({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  /// Not `~/.claude/`. The MCP servers live in the dotfile beside that
  /// directory, which is a genuinely confusing split — `~/.claude/settings.json`
  /// (which `ClientAppConfigurator` writes) and `~/.claude.json` are different
  /// files owned by the same program.
  File get file => File('$_home/.claude.json');

  /// The user-scope table: available in every project, which is the only scope
  /// that matches what a connector is.
  ///
  /// Deliberately *not* `projects[cwd].mcpServers`. A connector belongs to the
  /// person, not to a directory — projecting into the local scope would make
  /// Gmail appear in one folder and vanish in the next, and there is no cwd for
  /// a desktop app to sensibly pick anyway.
  static const String _section = 'mcpServers';

  /// The keys this app understands and therefore owns on a write.
  ///
  /// Everything else in a server's entry belongs to whoever put it there and is
  /// copied through untouched — see [upsert]. Claude Code preserves unknown
  /// keys (measured), so this cuts both ways: it keeps *its* extra keys as
  /// surely as it keeps ours.
  static const Set<String> _ownedKeys = {
    'type',
    'command',
    'args',
    'env',
    'url',
    'headers',
  };

  /// The configured servers, or an empty list when the file or the section is
  /// missing. Never throws — a broken config reads as "no servers", the same
  /// contract the other two readers offer.
  Future<List<McpServer>> read() async {
    try {
      return parseMcpServers((await _document())[_section]);
    } on Object {
      return const [];
    }
  }

  /// Every user-scope entry, values left opaque.
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

  /// Add or replace [server], keyed by its name, with a `.bak` written first.
  ///
  /// **Only the transport keys are replaced.** An entry can carry fields this
  /// app has no model for, and a read-into-[McpServer] round trip would drop
  /// them because [McpServer] cannot hold what it cannot parse. The stale owned
  /// keys are cleared first: a server edited from stdio to HTTP must not keep a
  /// `command` beside its new `url`, which would read as both transports at
  /// once.
  Future<void> upsert(McpServer server) async {
    await _edit((root) {
      _mergeEntry(_childMap(root, _section), server.name, _encode(server));
    });
  }

  /// Apply a batch of upserts and removals in **one** read-modify-write.
  ///
  /// One pass, not a loop over [upsert] and [remove]: every write re-encodes a
  /// 72 KB document and copies a `.bak`, so N calls would mean N rewrites of the
  /// user's file — and N chances for a crash to land between two of them.
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
        final value = entry.value;
        _mergeEntry(servers, entry.key, value is Map ? value : const {});
      }
    });
  }

  /// Remove the server named [name]; a no-op when it isn't there.
  ///
  /// The guard is not merely an optimisation: without it every call would
  /// rewrite the user's entire Claude Code state to change nothing.
  Future<void> remove(String name) async {
    final servers = (await _document())[_section];
    if (servers is! Map || !servers.containsKey(name)) return;
    await _edit((root) {
      final existing = root[_section];
      if (existing is Map) existing.remove(name);
    });
  }

  /// Write [value]'s keys over the entry at [name], keeping unmodelled fields.
  void _mergeEntry(
    Map<String, dynamic> servers,
    String name,
    Map<Object?, Object?> value,
  ) {
    final existing = servers[name];
    final entry = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    entry.removeWhere((key, _) => _ownedKeys.contains(key));
    for (final field in value.entries) {
      entry['${field.key}'] = field.value;
    }
    servers[name] = entry;
  }

  /// One server in the shape Claude Code writes.
  ///
  /// The `type` discriminator is explicit rather than inferred from which keys
  /// are present: `claude mcp add --transport http` writes `"type": "http"`, and
  /// an entry without it is read as stdio.
  ///
  /// **Headers are kept here and refused in the projection**, which is not a
  /// contradiction. This method serves [upsert], whose only caller is the user
  /// typing a server into the Add-custom dialog — those headers are theirs, and
  /// dropping them would save a server that cannot authenticate. What must never
  /// be written is a header the *app* holds on the user's behalf; that decision
  /// belongs to [ClaudeConnectorServers.entryFor], which refuses it.
  Map<String, Object?> _encode(McpServer server) => switch (server.transport) {
    McpStdio(:final command, :final args, :final env) => {
      'type': 'stdio',
      'command': command,
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    },
    McpHttp(:final url, :final headers) => {
      'type': 'http',
      'url': url,
      if (headers.isNotEmpty) 'headers': headers,
    },
  };

  /// Decode the file into a mutable tree, or an empty one when it isn't there.
  ///
  /// Deeply mutable, for the same reason [CodexMcpConfig] does it: doing the
  /// copy lazily would leave untouched branches aliased to the parsed document,
  /// which is fine for reading and a trap the first time someone edits one.
  Future<Map<String, dynamic>> _document() async {
    if (!await file.exists()) return <String, dynamic>{};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is! Map) return <String, dynamic>{};
    return _deepCopy(decoded);
  }

  Future<void> _edit(void Function(Map<String, dynamic> root) change) async {
    final root = await _document();
    change(root);
    // An empty `mcpServers` object is harmless but reads as debris once the
    // last server is removed — and its absence is the state a fresh install is
    // in, so leaving it behind would be a footprint from an app the user may
    // have since disconnected.
    final servers = root[_section];
    if (servers is Map && servers.isEmpty) root.remove(_section);

    await file.parent.create(recursive: true);
    // A backup before every write. This file is 72 KB of the user's Claude Code
    // state — projects, history, onboarding — and a bad edit is not recoverable
    // from anywhere else.
    if (await file.exists()) await file.copy('${file.path}.bak');
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(root)}\n',
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

  static Map<String, dynamic> _deepCopy(Map<Object?, Object?> source) {
    return {
      for (final entry in source.entries)
        '${entry.key}': _copyValue(entry.value),
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
