import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_version_service.dart';
import '../../../../infrastructure/cli/host_environment.dart';

/// Claude Code — Anthropic's coding agent, run as a chat agent the app drives
/// over `claude -p`, in its own text mode.
///
/// Unlike Hermes and Codex, it isn't fetched from a recipe of ours: it ships its
/// own installer, which knows its release channel better than a pinned URL here
/// would — see [ClaudeInstaller]. Once it's here it behaves like the others:
/// found on the augmented PATH, nothing for the user to pick.
const String claudeExecutable = 'claude';

/// Absolute path to the Claude Code binary, or null when it isn't installed yet.
/// Invalidate to re-probe after an install.
final claudePathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable(claudeExecutable),
);

/// Whether Claude Code is installed on this computer.
final claudeInstalledProvider = Provider<bool>(
  (ref) => ref.watch(claudePathProvider) != null,
);

/// Null when Claude Code isn't installed — there's nothing to ask.
final claudeVersionServiceProvider = Provider<AgentVersionService?>((ref) {
  final path = ref.watch(claudePathProvider);
  return path == null
      ? null
      : AgentBinaryVersionService(path, parse: parseSemver);
});

/// The installed Claude Code version, or null when there's no agent (or it
/// didn't say). `claude --version` answers `2.1.183 (Claude Code)`, so the bare
/// semver is pulled out of that line — see [parseSemver]. Invalidate after an
/// install.
final claudeVersionProvider = FutureProvider<String?>(
  (ref) async => ref.watch(claudeVersionServiceProvider)?.version(),
);

/// Whether [help] — the text of `claude --help` — offers the browser flag.
///
/// Asking the binary beats comparing versions: `--chrome` is on the 2.1.183
/// installed here, while the version the docs first name for the integration's
/// *install prompt* is 2.1.206, so a semver gate would shut the lane on a
/// machine that can run it. Pure, so the parse is tested without a binary.
bool claudeHelpNamesChrome(String help) => help.contains('--chrome');

/// Whether this Claude Code build can drive the browser extension at all.
///
/// False when Claude Code isn't installed, when `--help` can't be read, and when
/// it names no `--chrome`: all three mean the same to a caller — don't pass the
/// flag — and none of them is worth a failed turn to discover.
final claudeSupportsChromeProvider = FutureProvider<bool>((ref) async {
  final path = ref.watch(claudePathProvider);
  if (path == null) return false;
  try {
    final result = await Process.run(
      path,
      const ['--help'],
      environment: {'PATH': HostEnvironment.path()},
    );
    return claudeHelpNamesChrome('${result.stdout}');
  } on ProcessException {
    return false;
  }
});
