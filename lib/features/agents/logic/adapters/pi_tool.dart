import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_version_service.dart';
import '../../../../infrastructure/cli/host_environment.dart';

/// Pi — a minimal terminal coding harness, run as a chat agent the app drives
/// over `pi --mode json`. The app installs it — a private, pinned Node into
/// `~/.grid` and then Pi via that Node's npm — and finds it on the augmented
/// PATH, the same way Hermes and Codex are; there's no bundled sidecar and
/// nothing for the user to pick.
const String piExecutable = 'pi';

/// Absolute path to the Pi binary, or null when it isn't installed yet.
/// Invalidate to re-probe after an install.
final piPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable(piExecutable),
);

/// Whether Pi is installed on this computer.
final piInstalledProvider = Provider<bool>(
  (ref) => ref.watch(piPathProvider) != null,
);

/// Null when Pi isn't installed — there's nothing to ask.
final piVersionServiceProvider = Provider<AgentVersionService?>((ref) {
  final path = ref.watch(piPathProvider);
  return path == null
      ? null
      : AgentBinaryVersionService(path, parse: parseSemver);
});

/// The installed Pi version, or null when there's no agent (or it didn't say).
/// `pi --version` prints its bare semver, pulled out by [parseSemver].
/// Invalidate after an install.
final piVersionProvider = FutureProvider<String?>(
  (ref) async => ref.watch(piVersionServiceProvider)?.version(),
);
