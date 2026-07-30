import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/claude_installer.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'agent_catalog.dart';

/// Ceiling for a `grid agent install`, well past the default one-shot timeout:
/// it downloads a private CPython plus the agent's dependencies, which takes
/// minutes — and longer on an Intel Mac that has no prebuilt wheels and builds
/// from source. The old 60s default killed the install mid-download every time,
/// so both the silent top-up and the Agents-screen "Update" always failed. This
/// stays a ceiling, not a promise it finishes — a genuinely wedged install still
/// gives up rather than hanging forever.
const Duration kAgentInstallTimeout = Duration(minutes: 10);

/// The one place that knows *how* to put an agent on this computer.
///
/// Two routes, because the agents come from two places — `grid agent install`
/// for the ones the CLI packages (Hermes, Codex), the vendor's own installer for
/// Claude Code, which the CLI has no recipe for ([AgentTool.packagedByCli]). A
/// caller says only *which* agent; picking the route is this service's job, so
/// the Agents-tab button, the first-run installer and the background top-up can
/// never grow three different ideas of how a given agent installs.
///
/// [install] returns null on success, else a user-facing line — the CLI's own
/// last words, or the installer's, humanized at this boundary (§6) so no caller
/// has to translate an exit code.
class AgentInstaller {
  AgentInstaller(this._ref);

  final Ref _ref;

  Future<String?> install(AgentTool tool, {bool upgrade = false}) =>
      tool.packagedByCli
      ? _viaCli(tool, upgrade: upgrade)
      : _viaVendor(tool, upgrade: upgrade);

  /// `grid agent install <id>` — no Homebrew, no admin rights; it writes into
  /// `~/.grid`. `--force` replaces a build that's already there.
  Future<String?> _viaCli(AgentTool tool, {required bool upgrade}) async {
    final cli = _ref.read(gridCliServiceProvider);
    if (cli == null) {
      return "The grid tool isn't installed on this computer, so there's "
          'nothing to install ${tool.name} with.';
    }
    final result = await cli.run([
      'agent',
      'install',
      tool.id,
      if (upgrade) '--force',
    ], timeout: kAgentInstallTimeout);
    return result.ok ? null : _friendlyCliError(result, tool);
  }

  /// Claude Code from its vendor's own installer — the CLI knows only Hermes and
  /// Codex and rejects anything else at argv parsing, so routing Claude through
  /// it would fail every time with a usage error the user can do nothing about.
  Future<String?> _viaVendor(AgentTool tool, {required bool upgrade}) async {
    final failure = await _ref
        .read(claudeInstallerProvider)
        .install(upgrade: upgrade);
    // The raw line is kept, not swallowed: an installer that failed on a proxy
    // says so, and a sentence of ours would only hide it (§6).
    return failure == null ? null : "Couldn't install ${tool.name}: $failure";
  }

  /// The CLI's last words, or a plain sentence when it said nothing useful —
  /// never a bare exit code, which tells the user nothing they can act on.
  static String _friendlyCliError(CliResult result, AgentTool tool) {
    final detail = [
      ...result.stderr.trim().split('\n'),
      ...result.stdout.trim().split('\n'),
    ].map((line) => line.trim()).where((line) => line.isNotEmpty).lastOrNull;

    if (detail == null) {
      return "Couldn't install ${tool.name}. Check your connection and try "
          'again.';
    }
    return "Couldn't install ${tool.name}: $detail";
  }
}

/// Wired through the container so the install controller and the background
/// top-up share one installer, and tests hand it a fake that downloads nothing.
final agentInstallerProvider = Provider<AgentInstaller>(AgentInstaller.new);
