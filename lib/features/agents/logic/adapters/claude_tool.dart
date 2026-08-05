import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_version_service.dart';
import '../../../../infrastructure/cli/host_environment.dart';

/// Claude Code — Anthropic's coding agent, run as a chat agent the app drives
/// over `claude -p --output-format stream-json`.
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
