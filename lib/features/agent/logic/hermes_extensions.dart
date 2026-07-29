import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_config_file.dart';
import '../../../infrastructure/cli/hermes_plugin_service.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_plugin.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import '../../agents/logic/skill_writer.dart';
import '../../skills/logic/skill_author.dart';
import 'hermes_connector_servers.dart';
import 'hermes_mcp_config.dart';
import 'hermes_token_projection.dart';
import 'agent_skill_installer.dart';
import 'hermes_skill_scanner.dart';
import 'hermes_tool.dart';

/// Hermes's extension surfaces, composed from the services that already speak
/// to it. Nothing here talks to Hermes directly — this is wiring, so each
/// underlying seam stays overridable in tests on its own.
class HermesExtensions implements AgentExtensions {
  HermesExtensions({
    required HermesPluginService? pluginService,
    required HermesMcpConfig mcpConfig,
    required AgentSkillScanner scanner,
    required SkillAuthor author,
    required AgentSkillInstaller installer,
    required HermesConfigFile configFile,
    required HermesTokenProjection tokenProjection,
    required HermesConnectorServers connectorServers,
  }) : skills = _HermesSkillsPlane(scanner, author, installer, configFile),
       plugins = pluginService == null
           ? null
           : _HermesPluginsPlane(pluginService),
       mcp = _HermesMcpPlane(mcpConfig, tokenProjection, connectorServers);

  @override
  AgentTool get tool => AgentTool.hermes;

  /// File-based, so present even while the binary is missing — the skills are
  /// still on disk and the user can still read them.
  @override
  final AgentSkillsPlane skills;

  /// Null when the hermes binary can't be found: the plugin manager IS the CLI,
  /// so without the binary there is nothing to list or flip.
  @override
  final AgentPluginsPlane? plugins;

  @override
  final AgentMcpPlane mcp;
}

/// The literal entry written into `skills.external_dirs` — home-relative on
/// purpose: Hermes expands `~` itself, so the config stays valid if the home
/// directory moves with a new username.
const String kSharedSkillsExternalDir = '~/.grid/skills';

class _HermesSkillsPlane implements AgentSkillsPlane {
  _HermesSkillsPlane(
    this._scanner,
    this._author,
    this._installer,
    this._configFile,
  );

  final AgentSkillScanner _scanner;
  final SkillAuthor _author;
  final AgentSkillInstaller _installer;
  final HermesConfigFile _configFile;

  @override
  Future<List<AgentSkill>> list() => _scanner.scan();

  @override
  SkillWriter? get writer => _author;

  @override
  Future<void> installGridSkills() => _installer.install(AgentTool.hermes);

  /// Merge the shared store into `skills.external_dirs` — append-if-absent,
  /// never clobbering entries the user set by hand. Hermes tolerates a bare
  /// string where a list is expected, so both shapes are read.
  @override
  Future<void> projectSharedStore() async {
    final existing = await _configFile.valueAt(['skills', 'external_dirs']);
    final dirs = switch (existing) {
      final List list => [for (final entry in list) entry.toString()],
      final String single => [single],
      _ => <String>[],
    };
    if (dirs.contains(kSharedSkillsExternalDir)) return;
    await _configFile.edit((editor) {
      HermesConfigFile.upsert(
        editor,
        ['skills', 'external_dirs'],
        [...dirs, kSharedSkillsExternalDir],
      );
    });
  }
}

class _HermesPluginsPlane implements AgentPluginsPlane {
  _HermesPluginsPlane(this._service);

  final HermesPluginService _service;

  @override
  Future<List<AgentPlugin>> list() async {
    final raw = await _service.listJson();
    if (raw.trim().isEmpty) return const [];
    return parseHermesPlugins(raw);
  }

  @override
  Future<void> install(String identifier) =>
      _run(() => _service.install(identifier));

  @override
  Future<void> setEnabled(String name, {required bool enabled}) =>
      _run(() => enabled ? _service.enable(name) : _service.disable(name));

  @override
  Future<void> remove(String name) => _run(() => _service.remove(name));

  /// Hermes's own failure type becomes the contract's, so controllers surface
  /// its message without importing anything hermes-shaped.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on HermesPluginException catch (error) {
      throw AgentExtensionException(error.message);
    }
  }
}

class _HermesMcpPlane implements AgentMcpPlane {
  _HermesMcpPlane(this._config, this._tokens, this._servers);

  final HermesMcpConfig _config;
  final HermesTokenProjection _tokens;
  final HermesConnectorServers _servers;

  /// Give Hermes both halves of a connector: the credential in its own
  /// `mcp-tokens/` directory, and the `mcp_servers` entry that tells it the
  /// connector exists at all.
  ///
  /// Neither half works alone. A token file with no config entry is an orphan
  /// Hermes never opens; a config entry with no token is a server it can't
  /// authenticate against. The order below is deliberate — credential first, so
  /// there is no moment where the agent knows about a server it cannot reach.
  @override
  Future<void> Function(List<ConnectorToken>)? get projectConnectorTokens =>
      (tokens) async {
        try {
          // Ask the config which connectors we already own *before* writing, so
          // deletions are driven by what is really on disk rather than by the
          // list being written — which can only ever say "everything here is
          // wanted" and would leave a disconnected connector's file behind.
          final owned = await _servers.owned();
          await _tokens.project(
            tokens,
            owned: {...owned, for (final token in tokens) token.connector},
          );
          await _servers.project(tokens);
        } on Object catch (error) {
          throw AgentExtensionException(
            "Couldn't hand the connector tokens to Hermes: $error",
          );
        }
      };

  @override
  Future<Set<String>> connectorEntries() => _servers.owned();

  @override
  Future<List<McpServer>> read() => _config.read();

  @override
  Future<void> upsert(McpServer server) => _config.upsert(server);

  @override
  Future<void> remove(String name) => _config.remove(name);

  @override
  Future<void> rename(String previousName, McpServer server) async {
    // Remove first: saving under the new name and then failing to remove the
    // old would leave two live servers; the reverse order at worst re-runs.
    if (previousName != server.name) await _config.remove(previousName);
    await _config.upsert(server);
  }
}

/// Reads `hermes plugins list --json`.
///
/// Lenient: a field Hermes renames must not blank the screen, so an unreadable
/// entry is skipped and the rest still show. Hermes prints the state as a phrase
/// ("enabled" / "not enabled"), so that's what we match on.
List<AgentPlugin> parseHermesPlugins(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) return const [];

  final plugins = <AgentPlugin>[];
  for (final raw in decoded) {
    if (raw is! Map<String, dynamic>) continue;
    final name = raw['name'];
    if (name is! String || name.isEmpty) continue;
    plugins.add(
      AgentPlugin(
        name: name,
        description: _string(raw['description']),
        version: _string(raw['version']),
        enabled: _string(raw['status']).toLowerCase() == 'enabled',
        bundled: _string(raw['source']).toLowerCase() == 'bundled',
      ),
    );
  }
  plugins.sort((a, b) => a.name.compareTo(b.name));
  return plugins;
}

String _string(Object? raw) => raw is String ? raw : '';

/// The plugin manager seam, or null when the agent isn't installed.
final hermesPluginServiceProvider = Provider<HermesPluginService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesPluginServiceImpl(path);
});

/// The MCP config seam. A plain provider so tests can point it at a temp home.
final hermesMcpConfigProvider = Provider<HermesMcpConfig>(
  (ref) => HermesMcpConfig(),
);

/// The config.yaml seam for the skills plane's `external_dirs` projection.
final hermesConfigFileProvider = Provider<HermesConfigFile>(
  (ref) => HermesConfigFile(),
);

/// The `mcp_servers` half of the connector projection.
final hermesConnectorServersProvider = Provider<HermesConnectorServers>(
  (ref) => HermesConnectorServers(),
);

/// Hermes's extension adapter. Always present — the skills and MCP planes are
/// file-based and outlive the binary — with the plugins plane going null when
/// the binary is missing. The screens' whole-page gate stays
/// `hermesInstalledProvider`, same as before the adapter existed.
final hermesExtensionsProvider = Provider<AgentExtensions?>((ref) {
  return HermesExtensions(
    pluginService: ref.watch(hermesPluginServiceProvider),
    mcpConfig: ref.watch(hermesMcpConfigProvider),
    scanner: ref.watch(agentSkillScannerProvider),
    author: ref.watch(skillAuthorProvider),
    installer: ref.watch(agentSkillInstallerProvider),
    configFile: ref.watch(hermesConfigFileProvider),
    tokenProjection: ref.watch(hermesTokenProjectionProvider),
    connectorServers: ref.watch(hermesConnectorServersProvider),
  );
});
