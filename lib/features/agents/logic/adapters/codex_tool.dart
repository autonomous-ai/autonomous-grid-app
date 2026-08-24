import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_version_service.dart';
import '../../../../infrastructure/cli/host_environment.dart';

/// Codex — OpenAI's coding agent, run as a chat agent the app drives over
/// `codex exec`, in its own text mode. The app installs it — a pinned, hash-verified release
/// binary into `~/.grid/bin` — and finds it on the augmented PATH, the same way
/// Hermes is; there's no bundled sidecar and nothing for the user to pick.
const String codexExecutable = 'codex';

/// Absolute path to the Codex binary, or null when it isn't installed yet.
/// Invalidate to re-probe after an install.
final codexPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable(codexExecutable),
);

/// Whether Codex is installed on this computer.
final codexInstalledProvider = Provider<bool>(
  (ref) => ref.watch(codexPathProvider) != null,
);

/// Null when Codex isn't installed — there's nothing to ask.
final codexVersionServiceProvider = Provider<AgentVersionService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null
      ? null
      : AgentBinaryVersionService(path, parse: parseSemver);
});

/// The installed Codex version, or null when there's no agent (or it didn't
/// say). Codex opens with `codex-cli 0.141.0`, so the bare semver is pulled out
/// of that line — see [parseSemver]. Invalidate after an install.
final codexVersionProvider = FutureProvider<String?>(
  (ref) async => ref.watch(codexVersionServiceProvider)?.version(),
);
