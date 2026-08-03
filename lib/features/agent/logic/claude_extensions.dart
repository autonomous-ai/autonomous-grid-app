import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/claude_plugin_service.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/mcp/connector_bridge_provider.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_plugin.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import '../../agents/logic/skill_writer.dart';
import '../../skills/logic/skill_author.dart';
import 'agent_skill_installer.dart';
import 'claude_connector_servers.dart';
import 'claude_mcp_config.dart';
import 'claude_tool.dart';
import 'hermes_skill_scanner.dart';

/// Claude Code's extension surfaces — the third adapter, and the first with all
/// three planes non-null.
///
/// Hermes has a plugin manager and Codex does not; Claude Code does, so the gap
/// [CodexExtensions] leaves is filled here rather than worked around. Every
/// plane is either a file this app already knows how to edit or a CLI verb that
/// was measured to exist, which is the bar a plane has to clear before it stops
/// being null.
class ClaudeExtensions implements AgentExtensions {
  ClaudeExtensions({
    required AgentSkillScanner scanner,
    required SkillAuthor author,
    required AgentSkillInstaller installer,
    required ClaudeMcpConfig mcpConfig,
    required ClaudeConnectorServers connectorServers,
    ClaudePluginService? pluginService,
    AppLog? log,
  }) : skills = _ClaudeSkillsPlane(scanner, author, installer),
       plugins = pluginService == null
           ? null
           : _ClaudePluginsPlane(pluginService),
       mcp = _ClaudeMcpPlane(mcpConfig, connectorServers, log);

  @override
  AgentTool get tool => AgentTool.claude;

  /// File-based (`~/.claude/skills`), so present even while the binary is
  /// missing — the skills are on disk and the user can still read them.
  @override
  final AgentSkillsPlane skills;

  /// Null only when the `claude` binary can't be found: the plugin manager *is*
  /// the CLI, so without it there is nothing to list or flip. That is the same
  /// rule Hermes follows, and a different reason from Codex's permanent null —
  /// Codex has no manager to drive at any version.
  @override
  final AgentPluginsPlane? plugins;

  @override
  final AgentMcpPlane mcp;
}

/// The same three agent-neutral services the other two adapters use.
///
/// [AgentSkillScanner] keys on [SkillSource], [AgentSkillInstaller] on
/// [AgentTool], and [SkillAuthor] writes to the shared library — and
/// `SkillSource.claude` (`~/.claude/skills`) plus three grid skills targeting
/// `AgentTool.claude` were already in place before this adapter existed. So this
/// plane is wiring, not new behaviour.
class _ClaudeSkillsPlane implements AgentSkillsPlane {
  _ClaudeSkillsPlane(this._scanner, this._author, this._installer);

  final AgentSkillScanner _scanner;
  final SkillAuthor _author;
  final AgentSkillInstaller _installer;

  @override
  Future<List<AgentSkill>> list(SkillSource source) => _scanner.scan(source);

  @override
  SkillWriter? get writer => _author;

  @override
  Future<void> installGridSkills() => _installer.install(AgentTool.claude);

  /// Nothing to detach, for the same reason as Codex.
  ///
  /// [AgentSkillsPlane.detachLibrary] undoes one specific historical mistake: an
  /// older build pointed Hermes at `~/.grid/skills` through
  /// `skills.external_dirs`, so every skill in the library went live whether or
  /// not it had been given to that agent. Claude Code was never wired that way,
  /// so there is no shortcut here to close — a no-op rather than a throw,
  /// because this is called before every write and means "make sure the shortcut
  /// is shut", which here is already true.
  @override
  Future<void> detachLibrary() async {}
}

class _ClaudePluginsPlane implements AgentPluginsPlane {
  _ClaudePluginsPlane(this._service);

  final ClaudePluginService _service;

  @override
  Future<List<AgentPlugin>> list() async {
    final raw = await _service.listJson();
    if (raw.trim().isEmpty) return const [];
    return parseClaudePluginList(raw);
  }

  @override
  Future<void> install(String identifier) =>
      _run(() => _service.install(identifier));

  @override
  Future<void> setEnabled(String name, {required bool enabled}) =>
      _run(() => enabled ? _service.enable(name) : _service.disable(name));

  @override
  Future<void> remove(String name) => _run(() => _service.remove(name));

  /// Claude Code's own failure type becomes the contract's, so controllers
  /// surface its message without importing anything claude-shaped.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on ClaudePluginException catch (error) {
      throw AgentExtensionException(error.message);
    }
  }
}

class _ClaudeMcpPlane implements AgentMcpPlane {
  _ClaudeMcpPlane(this._config, this._servers, this._log);

  final ClaudeMcpConfig _config;
  final ClaudeConnectorServers _servers;

  /// Nullable so tests construct this without one, and so a projection can never
  /// fail for want of a logger.
  final AppLog? _log;

  /// Read the file, not `claude mcp list`.
  ///
  /// The opposite of the Codex plane, which prefers its CLI — and measured, not
  /// preferred by habit. `claude mcp list` has **no `--json`**, and it
  /// **health-checks every server over the network** before printing, so on this
  /// machine two unreachable entries each blocked on an HTTP timeout. A screen
  /// that lists configured servers must not wait on the network to do it, and
  /// scraping a human-readable table that exists to show connection status would
  /// break the first time a status string changed.
  ///
  /// The file gives the same set of servers with none of that. What it cannot
  /// give is liveness — which this plane does not claim to show.
  @override
  Future<List<McpServer>> read() => _config.read();

  @override
  Future<void> upsert(McpServer server) => _config.upsert(server);

  @override
  Future<void> remove(String name) => _config.remove(name);

  @override
  Future<void> rename(String previousName, McpServer server) async {
    // Remove first, exactly as the other two planes do and for the same reason:
    // saving under the new name and then failing to remove the old would leave
    // two live servers, while the reverse order at worst re-runs.
    if (previousName != server.name) await _config.remove(previousName);
    await upsert(server);
  }

  @override
  Future<Set<String>> connectorEntries() => _servers.owned();

  /// Write the connector's *address* into Claude Code's config — never its
  /// credential.
  ///
  /// Half of what the Hermes plane does, because Claude Code needs half. Hermes
  /// gets a credential file plus a config entry; here there is no credential to
  /// place. A REST connector is reached through the app's own bridge, which
  /// attaches the token per call from the master store, and an MCP connector
  /// that would need a header is skipped rather than written insecurely
  /// ([ClaudeConnectorServers.entryFor]).
  ///
  /// So this, like the Codex projection, cannot leak a secret: the worst it can
  /// write is a URL.
  @override
  Future<void> Function(List<ConnectorToken> tokens, {Set<String> removing})?
  get projectConnectorTokens => (tokens, {removing = const {}}) async {
    try {
      await _servers.project(tokens, removing: removing);
      final after = await _servers.owned();
      // Named, not derived from a count difference. A connector with no
      // projectable address — a REST one before the bridge binds, or an MCP one
      // whose entry carries headers — is deliberately absent, so "3 tokens in,
      // 1 entry out" is a correct outcome rather than a bug. The same reading
      // mistake was made once on the Hermes log.
      final skipped = {
        for (final token in tokens)
          if (!after.contains(token.connector)) token.connector,
      };
      _log?.info(
        'connectors',
        'Claude Code projection: ${tokens.length} token(s), '
            'removing [${removing.join(', ')}] → config owns '
            '${after.length} [${after.join(', ')}]'
            '${skipped.isEmpty ? '' : ', not projectable [${skipped.join(', ')}]'}',
      );
    } on Object catch (error, stack) {
      _log?.failure(
        'connectors',
        'Claude Code projection failed',
        error: error,
        stackTrace: stack,
      );
      throw AgentExtensionException(
        "Couldn't hand the connector addresses to Claude Code: $error",
      );
    }
  };
}

/// The MCP config seam. A plain provider so tests can point it at a temp home,
/// matching `hermesMcpConfigProvider` and `codexMcpConfigProvider`.
final claudeMcpConfigProvider = Provider<ClaudeMcpConfig>(
  (ref) => ClaudeMcpConfig(),
);

/// Claude Code's plugin manager, or null when the binary isn't installed.
final claudePluginServiceProvider = Provider<ClaudePluginService?>((ref) {
  final path = ref.watch(claudePathProvider);
  return path == null ? null : ClaudePluginServiceImpl(path);
});

/// The connector projection into Claude Code's config.
///
/// Handed the bridge's endpoint resolver rather than the bridge itself, exactly
/// as the other two are: the projection's only question is "what URL, if any,
/// serves this connector right now", and null is an answer it already handles.
final claudeConnectorServersProvider = Provider<ClaudeConnectorServers>(
  (ref) => ClaudeConnectorServers(
    config: ref.watch(claudeMcpConfigProvider),
    bridgeEndpointFor: ref.read(connectorBridgeProvider).endpointFor,
  ),
);

/// Claude Code's extension adapter. Always present — skills and MCP are
/// file-based and outlive the binary; only the plugins plane needs the CLI.
final claudeExtensionsProvider = Provider<AgentExtensions?>((ref) {
  return ClaudeExtensions(
    scanner: ref.watch(agentSkillScannerProvider),
    author: ref.watch(skillAuthorProvider),
    installer: ref.watch(agentSkillInstallerProvider),
    mcpConfig: ref.watch(claudeMcpConfigProvider),
    connectorServers: ref.watch(claudeConnectorServersProvider),
    pluginService: ref.watch(claudePluginServiceProvider),
    log: ref.watch(appLogProvider),
  );
});
