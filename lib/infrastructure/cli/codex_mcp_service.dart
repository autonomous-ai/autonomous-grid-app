import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// Raised when a `codex mcp` command fails, carrying the line the CLI printed so
/// the controller can show it instead of inventing a message.
class CodexMcpException implements Exception {
  const CodexMcpException(this.message);

  final String message;

  @override
  String toString() => 'CodexMcpException: $message';
}

/// The seam onto Codex's own MCP manager (`codex mcp`).
///
/// Codex ships a real subcommand for this — `list --json`, `add`, `remove` — so
/// the app asks the agent what it is configured with rather than re-deriving it
/// from `~/.codex/config.toml`. Same reasoning as `HermesPluginService`: the
/// screen cannot disagree with what the agent will actually load, and a format
/// change inside Codex is Codex's problem rather than a silently wrong list
/// here.
///
/// **Reads only, for now.** `add` and `remove` are deliberately absent: `codex
/// mcp add` starts an OAuth flow of its own the moment the URL supports it
/// (measured 2026-08-03 — it opened a browser and printed an authorize URL),
/// which is a whole interaction model, not a write. Writes still go through
/// `CodexMcpConfig`, which touches only the keys it owns.
abstract interface class CodexMcpService {
  /// Every server Codex knows about, as `codex mcp list --json` prints it.
  Future<String> listJson();
}

/// Real implementation: spawns the `codex` binary.
class CodexMcpServiceImpl implements CodexMcpService {
  const CodexMcpServiceImpl(this.binPath);

  /// Absolute path to the codex binary (it isn't on a GUI app's default PATH).
  final String binPath;

  @override
  Future<String> listJson() async {
    final result = await Process.run(binPath, const [
      'mcp',
      'list',
      '--json',
    ], environment: HostEnvironment.hermesEnvironment());
    if (result.exitCode != 0) {
      final stderrText = '${result.stderr}'.trim();
      throw CodexMcpException(
        stderrText.isEmpty
            ? 'codex mcp list failed (${result.exitCode}).'
            : stderrText,
      );
    }
    return '${result.stdout}';
  }
}

/// One server as `codex mcp list --json` describes it.
///
/// Richer than the TOML it is derived from, and two of the extra fields matter
/// enough to parse: [enabled] (a server can sit in the config switched off) and
/// [transport], which states `stdio` or `streamable_http` outright instead of
/// leaving it to be inferred from which keys are present.
///
/// Lenient in the same way every other reader here is: a row this can't read
/// drops itself and the rest still render. Codex is on an alpha channel
/// (`0.146.0-alpha.3.1` on this machine), so a renamed field must not blank the
/// screen.
List<CodexMcpEntry> parseCodexMcpList(String rawJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];

  final entries = <CodexMcpEntry>[];
  for (final row in decoded) {
    if (row is! Map) continue;
    final name = row['name'];
    if (name is! String || name.trim().isEmpty) continue;
    final transport = row['transport'];
    if (transport is! Map) continue;

    final type = transport['type'];
    final CodexMcpTransport? parsed = switch (type) {
      'stdio' => _stdio(transport),
      // Codex's own name for a remote server. Matched exactly rather than
      // "anything that isn't stdio": an unknown transport is a shape this app
      // has never seen, and guessing it is a URL would put a broken row on the
      // screen.
      'streamable_http' => _http(transport),
      _ => null,
    };
    if (parsed == null) continue;

    entries.add(
      CodexMcpEntry(
        name: name.trim(),
        transport: parsed,
        // Absent reads as enabled: Codex omits the flag for a plain server, and
        // defaulting to disabled would grey out every ordinary row.
        enabled: row['enabled'] != false,
        authStatus: row['auth_status'] is String
            ? row['auth_status'] as String
            : '',
      ),
    );
  }
  return entries;
}

CodexMcpTransport? _stdio(Map transport) {
  final command = transport['command'];
  if (command is! String || command.trim().isEmpty) return null;
  return CodexMcpStdio(
    command: command,
    args: [
      for (final arg
          in transport['args'] is List ? transport['args'] as List : const [])
        '$arg',
    ],
    // `env` is null rather than absent for a server with none, which `is Map`
    // already handles — spelled out because the real config on this machine
    // shows both forms.
    env: {
      if (transport['env'] is Map)
        for (final entry in (transport['env'] as Map).entries)
          '${entry.key}': '${entry.value}',
    },
  );
}

CodexMcpTransport? _http(Map transport) {
  final url = transport['url'];
  if (url is! String || url.trim().isEmpty) return null;
  return CodexMcpHttp(url: url);
}

/// How Codex reaches one server.
sealed class CodexMcpTransport {
  const CodexMcpTransport();
}

class CodexMcpStdio extends CodexMcpTransport {
  const CodexMcpStdio({
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  final String command;
  final List<String> args;
  final Map<String, String> env;
}

class CodexMcpHttp extends CodexMcpTransport {
  const CodexMcpHttp({required this.url});

  final String url;
}

/// One row of `codex mcp list --json`.
class CodexMcpEntry {
  const CodexMcpEntry({
    required this.name,
    required this.transport,
    this.enabled = true,
    this.authStatus = '',
  });

  final String name;
  final CodexMcpTransport transport;

  /// A server present in the config but switched off. Codex still lists it, and
  /// so does the app — hiding it would make "why isn't this here" unanswerable
  /// from the screen that owns the list.
  final bool enabled;

  /// Codex's own word for the sign-in state: `unsupported` for a plain stdio
  /// server, and an OAuth-flavoured value for one that has a login. Carried
  /// through rather than interpreted — nothing reads it yet, and inventing a
  /// meaning for a field on an alpha CLI is how a screen starts lying.
  final String authStatus;
}
