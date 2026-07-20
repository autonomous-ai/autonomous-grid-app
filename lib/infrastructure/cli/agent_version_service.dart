import 'dart:io';

/// Which build of an installed agent this computer has.
///
/// One seam behind every agent's `--version` probe: Hermes and Codex differ only
/// in the banner they print, so the parsing that turns that banner into a plain
/// `1.2.3` is the only thing that varies — see [AgentBinaryVersionService].
abstract interface class AgentVersionService {
  /// The installed version (`0.18.2`), or null when the binary answers with
  /// something that isn't one.
  Future<String?> version();
}

/// Runs `<executable> --version` and hands its output to [parse].
///
/// [parse] is the agent-specific bit — Hermes opens with `... v0.18.2 ...`, Codex
/// with `codex-cli 0.141.0` — so each agent supplies the reader that pulls the
/// number out of its own banner.
class AgentBinaryVersionService implements AgentVersionService {
  const AgentBinaryVersionService(this.executable, {required this.parse});

  final String executable;

  /// Turns the `--version` output into a bare `1.2.3`, or null when it isn't one.
  final String? Function(String output) parse;

  @override
  Future<String?> version() async {
    try {
      final result = await Process.run(executable, ['--version']);
      return parse('${result.stdout}');
    } on ProcessException {
      // The binary was on PATH a moment ago and isn't now (mid-upgrade, say) —
      // no version rather than a crash.
      return null;
    }
  }
}

/// The first `1.2.3` in [output], or null when there isn't one — the reader for a
/// tool whose banner leads with its name (`codex-cli 0.141.0`) rather than a
/// `v`-prefixed version. A binary that answers with something unexpected reads as
/// "unknown" instead of dumping a stray line onto the screen as if it were one.
String? parseSemver(String output) =>
    RegExp(r'(\d+\.\d+\.\d+)').firstMatch(output)?.group(1);
