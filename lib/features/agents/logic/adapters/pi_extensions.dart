import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/skills/agent_skill_home.dart';
import '../../../skills/logic/skill_author.dart';
import '../agent_catalog.dart';
import '../agent_extensions.dart';
import '../agent_skill.dart';
import '../agent_skill_installer.dart';
import '../skill_writer.dart';
import 'hermes_skill_scanner.dart';

/// Pi's extension surfaces — a skills plane and nothing else.
///
/// Pi ships no MCP, no plugin manager and no OAuth-connector concept on purpose
/// ("no built-in MCP, sub-agents, … build them as extensions or packages"), so
/// both of those planes are null — the null-plane rule doing its job, the same
/// way Codex's plugin plane is. What Pi *does* have is file-based skills under
/// `~/.pi/agent/skills` (the Agent Skills standard, the same shape Codex and
/// Claude Code read), so that plane is real and the adapter exists whether or
/// not the binary does — the files are on disk and the user can still read them.
class PiExtensions implements AgentExtensions {
  PiExtensions({
    required AgentSkillScanner scanner,
    required SkillAuthor author,
    required AgentSkillInstaller installer,
  }) : skills = _PiSkillsPlane(scanner, author, installer);

  @override
  AgentTool get tool => AgentTool.pi;

  @override
  final AgentSkillsPlane skills;

  /// Null — Pi has no plugin manager this app can drive.
  @override
  AgentPluginsPlane? get plugins => null;

  /// Null — Pi has no MCP concept at all, so there is nothing to read or write
  /// and no connector address to project.
  @override
  AgentMcpPlane? get mcp => null;
}

/// The same three services the Hermes and Codex skills planes use — all
/// agent-agnostic ([AgentSkillScanner] keys on [SkillSource], the installer on
/// [AgentTool]), so Pi's skills cost an adapter, not an implementation.
class _PiSkillsPlane implements AgentSkillsPlane {
  _PiSkillsPlane(this._scanner, this._author, this._installer);

  final AgentSkillScanner _scanner;
  final SkillAuthor _author;
  final AgentSkillInstaller _installer;

  @override
  Future<List<AgentSkill>> list(SkillSource source) => _scanner.scan(source);

  @override
  SkillWriter? get writer => _author;

  @override
  Future<void> installGridSkills() => _installer.install(AgentTool.pi);

  /// Nothing to detach — Pi was never pointed at the app's library, so there is
  /// no shortcut to close (see the Codex plane for the historical Hermes one).
  @override
  Future<void> detachLibrary() async {}
}

/// Pi's extension adapter. Always present — its one plane is file-based and
/// outlives the binary.
final piExtensionsProvider = Provider<AgentExtensions?>((ref) {
  return PiExtensions(
    scanner: ref.watch(agentSkillScannerProvider),
    author: ref.watch(skillAuthorProvider),
    installer: ref.watch(agentSkillInstallerProvider),
  );
});
