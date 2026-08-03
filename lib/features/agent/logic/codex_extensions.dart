import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/codex_mcp_service.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import '../../agents/logic/skill_writer.dart';
import '../../skills/logic/skill_author.dart';
import 'agent_skill_installer.dart';
import 'codex_mcp_config.dart';
import 'codex_tool.dart';
import 'hermes_skill_scanner.dart';

/// Codex's extension surfaces — the second adapter, and the one that proves the
/// contract in `agent_extensions.dart` was worth writing.
///
/// Everything here is file-based (`~/.codex/skills`, `~/.codex/config.toml`), so
/// the adapter exists whether or not the Codex binary does: the files are on
/// disk and the user can still read and edit them.
///
/// Two planes are deliberately narrower than Hermes's, and both narrowings are
/// the null-plane rule doing its job rather than work left undone — see
/// [plugins] and [AgentMcpPlane.projectConnectorTokens] below.
class CodexExtensions implements AgentExtensions {
  CodexExtensions({
    required AgentSkillScanner scanner,
    required SkillAuthor author,
    required AgentSkillInstaller installer,
    required CodexMcpConfig mcpConfig,
    CodexMcpService? mcpService,
  }) : skills = _CodexSkillsPlane(scanner, author, installer),
       mcp = _CodexMcpPlane(mcpConfig, mcpService);

  @override
  AgentTool get tool => AgentTool.codex;

  @override
  final AgentSkillsPlane skills;

  /// Null — Codex has no plugin manager this app can drive.
  ///
  /// Its `config.toml` does carry a `[plugins.*]` table, and that is a trap
  /// rather than an opportunity: those entries are written and owned by the
  /// ChatGPT desktop app (`browser@openai-bundled` and friends on this machine),
  /// not by a CLI the app could call. There is no install/enable/remove verb to
  /// put behind the screen's buttons, so the honest answer is "this agent has no
  /// such concept" — which is exactly what a null plane says.
  @override
  AgentPluginsPlane? get plugins => null;

  @override
  final AgentMcpPlane mcp;
}

/// The same three services Hermes's skills plane uses.
///
/// They were already agent-agnostic — [AgentSkillScanner] keys on [SkillSource],
/// [AgentSkillInstaller] on [AgentTool], and [SkillAuthor] writes to the shared
/// library — so this plane is wiring, not new behaviour. That is the payoff of
/// the contract: the second agent's skills cost an adapter, not an
/// implementation.
class _CodexSkillsPlane implements AgentSkillsPlane {
  _CodexSkillsPlane(this._scanner, this._author, this._installer);

  final AgentSkillScanner _scanner;
  final SkillAuthor _author;
  final AgentSkillInstaller _installer;

  @override
  Future<List<AgentSkill>> list(SkillSource source) => _scanner.scan(source);

  @override
  SkillWriter? get writer => _author;

  @override
  Future<void> installGridSkills() => _installer.install(AgentTool.codex);

  /// Nothing to detach.
  ///
  /// [AgentSkillsPlane.detachLibrary] undoes one specific historical mistake:
  /// an older build pointed Hermes at `~/.grid/skills` through
  /// `skills.external_dirs`, so every skill in the library went live for Hermes
  /// whether or not it had been given to Hermes. Codex was never wired that way
  /// and has no equivalent key, so there is no shortcut here to close.
  ///
  /// A no-op rather than a throw: this is called before every write, and it
  /// means "make sure the shortcut is shut" — which for Codex is already true.
  @override
  Future<void> detachLibrary() async {}
}

class _CodexMcpPlane implements AgentMcpPlane {
  _CodexMcpPlane(this._config, this._service);

  final CodexMcpConfig _config;

  /// Codex's own `codex mcp list --json`, or null when the binary isn't there.
  final CodexMcpService? _service;

  /// Ask Codex what it is configured with; fall back to reading the file.
  ///
  /// The CLI is the better answer for the reason `HermesPluginService` exists:
  /// it is the agent's own account of what it will load, so the screen cannot
  /// disagree with it. It also resolves things the file does not spell out — the
  /// transport is named (`stdio` / `streamable_http`) rather than inferred from
  /// which keys happen to be present, and a server switched off is reported as
  /// such instead of looking identical to a live one.
  ///
  /// The file stays as the fallback rather than being dropped, because the two
  /// disagree in a case that is not an error: the binary can be missing while
  /// `~/.codex/config.toml` is sitting right there with servers in it. Reading
  /// the file then is not a degraded answer, it is the correct one — the same
  /// reasoning that keeps the skills plane file-based.
  ///
  /// A CLI that answers with *nothing* also falls through. An empty list and a
  /// failed parse are indistinguishable from here, and a config with servers in
  /// it must not render empty because an alpha CLI renamed a field.
  @override
  Future<List<McpServer>> read() async {
    final service = _service;
    if (service != null) {
      try {
        final entries = parseCodexMcpList(await service.listJson());
        if (entries.isNotEmpty) return [for (final e in entries) _toModel(e)];
      } on Object {
        // Fall through: a CLI that won't answer is not a reason to show nothing
        // when the file can still be read.
      }
    }
    return _config.read();
  }

  /// Codex's richer row narrowed to the app's shared model.
  ///
  /// [CodexMcpEntry.enabled] and `authStatus` are dropped here, and that is a
  /// real loss worth naming: [McpServer] has nowhere to put them, so a server
  /// Codex has switched off renders exactly like a live one. Widening the shared
  /// model for one agent's extra column is the larger change, and it belongs
  /// with a screen that would show the difference — which does not exist yet.
  McpServer _toModel(CodexMcpEntry entry) => McpServer(
    name: entry.name,
    transport: switch (entry.transport) {
      CodexMcpStdio(:final command, :final args, :final env) => McpStdio(
        command: command,
        args: args,
        env: env,
      ),
      CodexMcpHttp(:final url) => McpHttp(url: url),
    },
  );

  @override
  Future<void> upsert(McpServer server) => _config.upsert(server);

  @override
  Future<void> remove(String name) => _config.remove(name);

  @override
  Future<void> rename(String previousName, McpServer server) async {
    // Remove first, exactly as the Hermes plane does and for the same reason:
    // saving under the new name and then failing to remove the old would leave
    // two live servers, while the reverse order at worst re-runs.
    if (previousName != server.name) await _config.remove(previousName);
    await upsert(server);
  }

  /// Empty — this app has never written a connector projection into Codex.
  ///
  /// The set answers "which entries did *we* write from a token", and its
  /// callers use it to avoid adopting a projection as a hand-typed server. With
  /// [projectConnectorTokens] null there are no such entries, so every server in
  /// Codex's config is genuinely the user's and the empty set is the true
  /// answer, not a stub.
  @override
  Future<Set<String>> connectorEntries() async => const {};

  /// Null — connector tokens are not projected into Codex yet, on purpose.
  ///
  /// Two separate reasons, either one sufficient:
  ///
  /// 1. **Codex's remote-MCP shape is unverified here.** Every connector is
  ///    HTTP, and nothing on this machine demonstrates how Codex expects a
  ///    remote server to be declared — the one real `config.toml` holds two
  ///    stdio servers and no `url` anywhere, and the binary is the ChatGPT app
  ///    bundle rather than a CLI that could be asked. Writing a guessed shape
  ///    produces a row the screen calls Connected and an agent that never had
  ///    the tools, which is the precise failure `_ensureMcpRuntime` exists to
  ///    prevent on the Hermes side.
  /// 2. **It would be D17 a second time.** That debt is a live credential in
  ///    `~/.hermes/config.yaml` — a file the user edits by hand, with a `.bak`
  ///    beside it. Codex's `config.toml` is the same kind of file, and this one
  ///    is shared with the ChatGPT desktop app. Repeating the shape before the
  ///    first instance is paid back would double a known violation of rule 5
  ///    rather than contain it.
  ///
  /// Null is not a gap in the screen: the Connectors screen reads it and says
  /// the agent doesn't support connectors, instead of promising a tool Codex
  /// could not call. Skills and hand-configured MCP servers work fully.
  @override
  Future<void> Function(List<ConnectorToken> tokens, {Set<String> removing})?
  get projectConnectorTokens => null;
}

/// The MCP config seam. A plain provider so tests can point it at a temp home,
/// matching `hermesMcpConfigProvider`.
final codexMcpConfigProvider = Provider<CodexMcpConfig>(
  (ref) => CodexMcpConfig(),
);

/// Codex's own `codex mcp` reader, or null when the binary isn't installed.
///
/// Null is not a failure state here — the plane falls back to the config file,
/// which is the right answer when there is no binary to ask.
final codexMcpServiceProvider = Provider<CodexMcpService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null ? null : CodexMcpServiceImpl(path);
});

/// Codex's extension adapter. Always present — both planes are file-based and
/// outlive the binary, with the CLI used to sharpen the MCP read when it is
/// there.
final codexExtensionsProvider = Provider<AgentExtensions?>((ref) {
  return CodexExtensions(
    scanner: ref.watch(agentSkillScannerProvider),
    author: ref.watch(skillAuthorProvider),
    installer: ref.watch(agentSkillInstallerProvider),
    mcpConfig: ref.watch(codexMcpConfigProvider),
    mcpService: ref.watch(codexMcpServiceProvider),
  );
});
