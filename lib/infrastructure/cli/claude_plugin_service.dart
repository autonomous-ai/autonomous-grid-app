import 'dart:convert';
import 'dart:io';

import '../../features/agents/logic/agent_plugin.dart';
import 'host_environment.dart';

/// Raised when a `claude plugin` command fails, carrying the line the CLI
/// printed so the controller can show it instead of inventing a message.
class ClaudePluginException implements Exception {
  const ClaudePluginException(this.message);

  final String message;

  @override
  String toString() => 'ClaudePluginException: $message';
}

/// The seam onto Claude Code's plugin manager (`claude plugin`).
///
/// The mirror of [HermesPluginService], and the reason Claude Code gets a
/// non-null plugins plane where Codex does not: measured on 2026-08-03, `claude
/// plugin` offers `list --json`, `install`, `enable`, `disable` and
/// `uninstall` — a verb behind every button the screen has. Codex's `[plugins.*]`
/// table is written by the ChatGPT desktop app with no CLI to drive it, which is
/// what a null plane is for.
abstract interface class ClaudePluginService {
  /// Every installed plugin, as the JSON `plugin list --json` prints.
  Future<String> listJson();

  /// Install from a marketplace id (`name@marketplace`) or a path.
  Future<void> install(String identifier);

  Future<void> enable(String name);
  Future<void> disable(String name);
  Future<void> remove(String name);
}

/// Real implementation: spawns the `claude` binary.
class ClaudePluginServiceImpl implements ClaudePluginService {
  const ClaudePluginServiceImpl(this.binPath);

  /// Absolute path to the claude binary (it isn't on a GUI app's default PATH).
  final String binPath;

  @override
  Future<String> listJson() => _run(['plugin', 'list', '--json']);

  /// Scope `user`, matching where the connectors go and for the same reason: a
  /// plugin the user installed from this app should be there in every project,
  /// not only in whichever directory the app happened to spawn the CLI from.
  @override
  Future<void> install(String identifier) async {
    await _run(['plugin', 'install', identifier, '--scope', 'user']);
  }

  @override
  Future<void> enable(String name) async {
    await _run(['plugin', 'enable', name]);
  }

  @override
  Future<void> disable(String name) async {
    await _run(['plugin', 'disable', name]);
  }

  @override
  Future<void> remove(String name) async {
    await _run(['plugin', 'uninstall', name]);
  }

  Future<String> _run(List<String> args) async {
    // `hermesEnvironment()` despite the agent: what is needed here is the
    // augmented PATH (a GUI app does not inherit the shell's), and that is the
    // only helper that builds one. The extra `HERMES_HOME` it sets is inert for
    // a `claude` process. `CodexMcpService` already spawns this way, so the
    // choice is the existing convention rather than a new one — a shared
    // `augmentedEnvironment()` is the rename that would fix all three at once.
    final result = await Process.run(
      binPath,
      args,
      environment: HostEnvironment.hermesEnvironment(),
    );
    final stdout = (result.stdout as String).trim();
    if (result.exitCode == 0) return stdout;
    final stderr = (result.stderr as String).trim();
    throw ClaudePluginException(stderr.isNotEmpty ? stderr : stdout);
  }
}

/// Read the plugins out of `claude plugin list --json`.
///
/// The measured shape (2026-08-03, `claude 2.1.220`) is a bare array:
///
/// ```json
/// [{"id": "agent-sdk-dev@claude-plugins-official", "version": "unknown",
///   "scope": "user", "enabled": true, "installPath": "…",
///   "installedAt": "…", "lastUpdated": "…"}]
/// ```
///
/// Two fields [AgentPlugin] wants are simply not in it, and both are rendered
/// honestly rather than faked:
///
/// - **No `description`.** It lives in the marketplace listing
///   (`list --available`), not in the installed record. An empty string is the
///   truthful answer; inventing one from the id would read as real text.
/// - **`version` is the literal string `"unknown"`** for a plugin installed
///   from a marketplace subdirectory — that is the CLI's own word, passed
///   through rather than blanked, because "unknown" is what the user will see
///   if they run the command themselves.
///
/// The `id` is `name@marketplace`; [AgentPlugin.name] takes the whole id because
/// that is the string every other verb (`enable`, `uninstall`) expects back.
///
/// Lenient by design, matching the Hermes parser: a row missing its id is
/// dropped rather than fatal, and unparseable input reads as no plugins.
List<AgentPlugin> parseClaudePluginList(String json) {
  try {
    final decoded = jsonDecode(json);
    // `list --available` answers with an object instead; take the installed
    // array from either shape so a flag added upstream cannot empty the screen.
    final rows = switch (decoded) {
      List() => decoded,
      Map() => decoded['installed'],
      _ => null,
    };
    if (rows is! List) return const [];
    final plugins = <AgentPlugin>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['id'];
      if (id is! String || id.trim().isEmpty) continue;
      plugins.add(
        AgentPlugin(
          name: id,
          description: '',
          version: row['version'] is String ? row['version'] as String : '',
          enabled: row['enabled'] == true,
          // Nothing ships with Claude Code the way Hermes bundles plugins:
          // every installed plugin came from a marketplace or a path, so every
          // one of them can be uninstalled.
          bundled: false,
        ),
      );
    }
    return plugins;
  } on Object {
    return const [];
  }
}
