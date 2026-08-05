import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/logic/adapters/hermes_tool.dart';
import 'agent_version_service.dart';

/// Null when Hermes isn't installed — there's nothing to ask.
final hermesVersionServiceProvider = Provider<AgentVersionService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null
      ? null
      : AgentBinaryVersionService(path, parse: parseHermesVersion);
});

/// The installed version, or null when there's no agent (or it didn't say).
///
/// Invalidate after an install so the screen shows the build that's now there.
final hermesVersionProvider = FutureProvider<String?>(
  (ref) async => ref.watch(hermesVersionServiceProvider)?.version(),
);

/// The version out of `hermes --version`, or null when the output isn't one.
///
/// Hermes opens with `Hermes Agent v0.18.2 (2026.7.7.2) · upstream 861d69c7` and
/// then lists its install directory and method. Only the version is worth
/// showing — and a binary that answers with something unexpected must read as
/// "unknown" rather than dumping a stray line onto the screen as if it were one.
String? parseHermesVersion(String output) =>
    RegExp(r'v(\d+\.\d+\.\d+)').firstMatch(output)?.group(1);
