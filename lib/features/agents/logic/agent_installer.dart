import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_spec_installer.dart';
import '../../../infrastructure/cli/claude_installer.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'agent_catalog.dart';

/// The one place that knows *how* to put an agent on this computer.
///
/// Two routes, because the agents come from two places — the app's own recipe
/// ([AgentTool.installSpec]) for the ones it fetches itself, the vendor's own
/// installer for Claude Code, which ships one. A caller says only *which* agent;
/// picking the route is this service's job, so the Agents-tab button, the
/// first-run installer and the background top-up can never grow three different
/// ideas of how a given agent installs.
///
/// [install] returns null on success, else a user-facing line — the installer's
/// own last words, humanized at this boundary (§6) so no caller has to translate
/// an exit code. The raw output goes to the app log as it happens, because a
/// download that stalls for minutes is otherwise invisible.
class AgentInstaller {
  AgentInstaller(this._ref);

  final Ref _ref;

  /// Install [tool], reporting the installer's own output to [onLog] as it
  /// arrives — a first install downloads a private Python or a release archive,
  /// and a screen with nothing to show for minutes reads as hung.
  Future<String?> install(
    AgentTool tool, {
    bool upgrade = false,
    void Function(String line)? onLog,
  }) {
    final spec = tool.installSpec;
    return spec == null
        ? _viaVendor(tool, upgrade: upgrade)
        : _viaSpec(tool, spec, onLog);
  }

  /// The app's own recipe: a pinned `uv` tool install, or a hash-verified
  /// release binary, both into `~/.grid`. There is no separate upgrade path —
  /// each recipe installs over whatever is there (`uv tool install --force`, a
  /// replaced binary), so install and update are the same run.
  Future<String?> _viaSpec(
    AgentTool tool,
    AgentInstallSpec spec,
    void Function(String line)? onLog,
  ) async {
    final log = _ref.read(appLogProvider);
    try {
      await _ref.read(agentSpecInstallerProvider).run(
        spec,
        onLog: (line) {
          log.info('agents', line);
          onLog?.call(line);
        },
      );
      return null;
    } on AgentInstallException catch (error) {
      log.failure('agents', 'install ${tool.id}: ${error.message}');
      return _friendlyInstallError(tool, error);
    } on Object catch (error, stack) {
      log.failure(
        'agents',
        'install ${tool.id} failed',
        error: error,
        stackTrace: stack,
      );
      return "Couldn't install ${tool.name}. Check your connection and try "
          'again.';
    }
  }

  /// Claude Code from its vendor's own installer — it knows its own release
  /// channel, where a URL pinned here would go stale the first time they move it.
  Future<String?> _viaVendor(AgentTool tool, {required bool upgrade}) async {
    final failure = await _ref
        .read(claudeInstallerProvider)
        .install(upgrade: upgrade);
    // The raw line is kept, not swallowed: an installer that failed on a proxy
    // says so, and a sentence of ours would only hide it (§6).
    return failure == null ? null : "Couldn't install ${tool.name}: $failure";
  }
}

/// The installer's reason in plain language — a transient start/download failure
/// invites a retry; anything else keeps the tool's own last line, which is the
/// only thing that says *what* went wrong.
String _friendlyInstallError(AgentTool tool, AgentInstallException error) =>
    error.retryable
    ? "Couldn't start installing ${tool.name}. Check your connection and try "
          'again.'
    : "Couldn't install ${tool.name}: ${error.message}";

/// Wired through the container so the install controller and the background
/// top-up share one installer, and tests hand it a fake that downloads nothing.
final agentInstallerProvider = Provider<AgentInstaller>(AgentInstaller.new);
