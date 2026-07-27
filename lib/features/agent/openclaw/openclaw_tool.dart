import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_version_service.dart';
import '../../../infrastructure/cli/host_environment.dart';

/// OpenClaw — a local agent driven headlessly over `openclaw infer model run`.
/// Found on the augmented PATH like the other agents; there's no bundled sidecar
/// and nothing for the user to pick.
const String openClawExecutable = 'openclaw';

/// Absolute path to the OpenClaw binary, or null when it isn't installed yet.
/// Invalidate to re-probe after an install.
final openClawPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable(openClawExecutable),
);

/// Whether OpenClaw is installed on this computer.
final openClawInstalledProvider = Provider<bool>(
  (ref) => ref.watch(openClawPathProvider) != null,
);

/// Null when OpenClaw isn't installed — there's nothing to ask.
final openClawVersionServiceProvider = Provider<AgentVersionService?>((ref) {
  final path = ref.watch(openClawPathProvider);
  return path == null
      ? null
      : AgentBinaryVersionService(path, parse: parseSemver);
});

/// The installed OpenClaw version, or null when there's no binary (or it didn't
/// say). Invalidate after an install.
final openClawVersionProvider = FutureProvider<String?>(
  (ref) async => ref.watch(openClawVersionServiceProvider)?.version(),
);
