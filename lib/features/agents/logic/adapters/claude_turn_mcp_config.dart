import 'dart:convert';
import 'dart:io';

import '../../../../core/grid_paths.dart';
import 'claude_connector_servers.dart';
import 'claude_mcp_config.dart';

/// Writes the `--mcp-config` document a Claude Code turn is launched with: the
/// connectors this app manages, and nothing else.
///
/// **Why a turn needs its own document at all.** `claude -p` loads every server
/// in `~/.claude.json`, handshakes them all in parallel, and closes the tool
/// list on whatever has answered by then. That file is the user's — `claude mcp
/// add` writes it, and so does every connector they authorize in claude.ai — so
/// its size is not this app's to control. Measured on this machine 2026-08-04
/// with 27 servers configured (24 of them `claude.ai` ones): across six
/// consecutive turns, `github` reached the tool list four times, `gmail` three,
/// and `googledrive` — the slowest of the three at 3.9s for its 51 tools —
/// **never once**. Six turns, six different answers to "can this agent read
/// mail". Restricting the same run to the three Grid connectors made it
/// `connected` with all 164 tools on 4 of 4 attempts.
///
/// That is the bug behind "Hermes reads my email and Claude Code doesn't". The
/// connector, the bridge, the token and the projection were all correct
/// throughout; the tools simply lost a race the user could not see and had no
/// way to influence.
///
/// **`--strict-mcp-config` is the half that does the work.** Without it this
/// document is *merged* with `~/.claude.json` and the field stays as crowded as
/// before. With it, it replaces the file for this process only — the user's own
/// config is neither read nor written, and their terminal Claude Code sessions
/// keep every server they configured.
///
/// The entries are read back from `~/.claude.json` rather than rebuilt from the
/// token store, so this cannot disagree with the projection about what a
/// connector's URL is: whatever [ClaudeConnectorServers] last wrote is exactly
/// what the turn is handed.
class ClaudeTurnMcpConfig {
  ClaudeTurnMcpConfig({ClaudeMcpConfig? source, String? home})
    : _source = source ?? ClaudeMcpConfig(home: home);

  final ClaudeMcpConfig _source;

  /// Written under `~/.grid`, not to a temp dir, for one reason: it is the
  /// argument of a command shown verbatim in the Debug tab, and a path that
  /// still exists after the turn is one the user can open and read.
  ///
  /// One file, rewritten per turn rather than one per turn: connectors change
  /// between turns (a sign-in, a disconnect) so it cannot be written once, and
  /// accumulating a file per turn would leave litter nobody ever collects.
  static File get file =>
      File('${GridPaths.home.path}/app/claude-mcp-config.json');

  /// The marker [ClaudeConnectorServers] stamps on entries it wrote.
  static const String _markerKey = ClaudeConnectorServers.markerKey;

  /// Write the document and return its path, or null if it could not be written.
  ///
  /// **Null means launch without the flag, and that distinction is the whole
  /// error contract.** `claude -p --mcp-config <missing path>` does not fall
  /// back — it exits with `Invalid MCP configuration: MCP config file not
  /// found` before the model is reached, so a failed write that still passed the
  /// path would turn a crowded tool list into no answer at all. Returning null
  /// leaves the turn on `~/.claude.json`: the behaviour that shipped before this
  /// class existed, which is degraded but never silent.
  /// [extra] adds servers this turn needs that the user's config has never
  /// heard of — the browser bridge, whose endpoint only exists once the app has
  /// started it. They are written here and nowhere else: `~/.claude.json` is the
  /// user's file, and an entry pointing at a port this app happens to be holding
  /// would outlive the session that made it true.
  Future<String?> write({Map<String, Object?> extra = const {}}) async {
    try {
      final entries = await _source.readRaw();
      final mine = <String, Object?>{
        for (final entry in entries.entries)
          if (_isOurs(entry.value)) entry.key: entry.value,
        ...extra,
      };
      // An empty `mcpServers` is valid and was measured as such: the turn starts
      // clean with 27 built-in tools and no MCP. That is the honest rendering of
      // "this user has no connectors" — merging with `~/.claude.json` instead
      // would hand a connector-less agent whatever the user's terminal config
      // happens to hold.
      final document = const JsonEncoder.withIndent(
        '  ',
      ).convert({'mcpServers': mine});

      await file.parent.create(recursive: true);
      await file.writeAsString('$document\n', flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  /// Whether an entry carries this app's marker.
  ///
  /// Marker-keyed, not name-keyed. A user who ran `claude mcp add gmail`
  /// themselves has an entry this app must not claim, and the `_grid` key is the
  /// only thing that separates the two — the same question
  /// [MarkedMapProjection] asks before deleting one.
  static bool _isOurs(Object? entry) =>
      entry is Map && entry[_markerKey] is Map<String, Object?>;
}
