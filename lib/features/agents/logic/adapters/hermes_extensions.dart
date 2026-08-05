import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_acp_setup.dart';
import '../../../../infrastructure/cli/hermes_config_file.dart';
import '../../../../infrastructure/cli/hermes_plugin_service.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/mcp/connector_bridge_provider.dart';
import '../../../../shared/skills/agent_skill_home.dart';
import '../agent_extensions.dart';
import '../agent_catalog.dart';
import '../agent_plugin.dart';
import '../agent_skill.dart';
import '../connector_token.dart';
import '../mcp_server.dart';
import '../skill_writer.dart';
import '../../../skills/logic/skill_author.dart';
import 'hermes_connector_servers.dart';
import 'hermes_mcp_config.dart';
import 'hermes_shared_skills.dart';
import 'hermes_token_projection.dart';
import '../agent_skill_installer.dart';
import 'hermes_skill_scanner.dart';
import 'hermes_tool.dart';

// The `external_dirs` entry moved next to the projection that writes it;
// re-exported so callers that reach it through this file keep working.
export 'hermes_shared_skills.dart' show kSharedSkillsExternalDir;

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
    HermesAcpSetup? setup,
    AppLog? log,
  }) : skills = _HermesSkillsPlane(scanner, author, installer, configFile),
       plugins = pluginService == null
           ? null
           : _HermesPluginsPlane(pluginService),
       mcp = _HermesMcpPlane(
         mcpConfig,
         tokenProjection,
         connectorServers,
         setup,
         log,
       );

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
  Future<List<AgentSkill>> list(SkillSource source) => _scanner.scan(source);

  @override
  SkillWriter? get writer => _author;

  @override
  Future<void> installGridSkills() => _installer.install(AgentTool.hermes);

  @override
  Future<void> detachLibrary() => unprojectSharedSkillsStore(_configFile);
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
  _HermesMcpPlane(
    this._config,
    this._tokens,
    this._servers,
    this._setup,
    this._log,
  );

  final HermesMcpConfig _config;
  final HermesTokenProjection _tokens;
  final HermesConnectorServers _servers;

  /// Null when the hermes binary isn't there to top up — the config can still be
  /// written, it just has nothing to run it yet.
  final HermesAcpSetup? _setup;

  /// Nullable so the existing tests keep constructing this without a logger, and
  /// so nothing here can fail for want of one — a projection must not break
  /// because diagnostics are absent.
  final AppLog? _log;

  /// Give Hermes both halves of a connector: the credential in its own
  /// `mcp-tokens/` directory, and the `mcp_servers` entry that tells it the
  /// connector exists at all.
  ///
  /// Neither half works alone. A token file with no config entry is an orphan
  /// Hermes never opens; a config entry with no token is a server it can't
  /// authenticate against. The order below is deliberate — credential first, so
  /// there is no moment where the agent knows about a server it cannot reach.
  @override
  Future<void> Function(List<ConnectorToken>, {Set<String> removing})?
  get projectConnectorTokens => (tokens, {removing = const {}}) async {
    try {
      final owned = await _servers.owned();
      _log?.info(
        'connectors',
        'Hermes projection: ${tokens.length} token(s) in '
            '[${tokens.map((t) => t.connector).join(', ')}], '
            'removing [${removing.join(', ')}], '
            'config already owns [${owned.join(', ')}] → '
            '${_servers.configFile.path}',
      );
      await _tokens.project(tokens, removing: removing);
      await _servers.project(tokens, removing: removing);
      _ensureMcpRuntime();
      // Read the config back, and check the one invariant that still holds now
      // that deletion is by name: every token with an MCP entry must be present
      // afterwards. The config may legitimately own *more* than we projected —
      // entries for connectors this call said nothing about are deliberately
      // left alone — so a larger count is not a fault.
      final after = await _servers.owned();
      final expected = {
        for (final token in tokens)
          if (token.mcpEntry != null) token.connector,
      };
      // Named explicitly rather than left as the arithmetic difference between
      // two counts. A connector the gateway has no MCP server for is stored,
      // linked and deliberately *not* written to the config — so "2 tokens in,
      // 1 entry out" is the correct outcome, and a reader comparing those two
      // numbers concludes a bug that isn't there. (I did, reading this log.)
      final toolless = {
        for (final token in tokens)
          if (token.mcpEntry == null) token.connector,
      };
      final missing = expected.difference(after);
      _log?.record(
        missing.isEmpty ? AppLogLevel.info : AppLogLevel.warn,
        'connectors',
        'Hermes projection done: config owns ${after.length} '
            '[${after.join(', ')}]'
            '${toolless.isEmpty ? '' : ', no MCP server yet for [${toolless.join(', ')}]'}'
            '${missing.isEmpty ? '' : ' — MISSING [${missing.join(', ')}]'}',
      );
    } on Object catch (error, stack) {
      _log?.failure(
        'connectors',
        'Hermes projection failed',
        error: error,
        stackTrace: stack,
      );
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
  Future<void> upsert(McpServer server) async {
    await _config.upsert(server);
    _ensureMcpRuntime();
  }

  @override
  Future<void> remove(String name) => _config.remove(name);

  @override
  Future<void> rename(String previousName, McpServer server) async {
    // Remove first: saving under the new name and then failing to remove the
    // old would leave two live servers; the reverse order at worst re-runs.
    if (previousName != server.name) await _config.remove(previousName);
    await upsert(server);
  }

  /// Make sure the MCP SDK is in Hermes's environment, now that its config names
  /// a server that needs one.
  ///
  /// Hermes imports that SDK inside a `try/except`: without it, every server
  /// written here is dropped on startup with no error, in the app or its logs —
  /// a connector the user signed into and a screen that shows it connected,
  /// while the agent never had the tools. Fire-and-forget: saving a server must
  /// not wait on an install, and Hermes reads the config when it next starts
  /// anyway.
  void _ensureMcpRuntime() {
    final setup = _setup;
    if (setup == null) return;
    unawaited(setup.ensureRuntimeSupport());
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
///
/// Handed the bridge's endpoint resolver rather than the bridge itself: the
/// adapter's only question is "what URL, if any, serves this connector right
/// now", and a null answer is a legitimate one it already handles.
final hermesConnectorServersProvider = Provider<HermesConnectorServers>(
  (ref) => HermesConnectorServers(
    bridgeEndpointFor: ref.read(connectorBridgeProvider).endpointFor,
  ),
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
    setup: ref.watch(hermesAcpSetupProvider),
    log: ref.watch(appLogProvider),
  );
});
