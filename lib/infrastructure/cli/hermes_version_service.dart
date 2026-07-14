import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agent/logic/hermes_tool.dart';

/// Which build of Hermes this computer has.
abstract interface class HermesVersionService {
  /// The installed version (`0.18.2`), or null when the binary answers with
  /// something that isn't one.
  Future<String?> version();
}

class HermesVersionServiceImpl implements HermesVersionService {
  const HermesVersionServiceImpl(this.executable);

  final String executable;

  @override
  Future<String?> version() async {
    try {
      final result = await Process.run(executable, ['--version']);
      return parseHermesVersion('${result.stdout}');
    } on ProcessException {
      // The binary was on PATH a moment ago and isn't now (mid-upgrade, say) —
      // no version rather than a crash.
      return null;
    }
  }
}

/// Null when Hermes isn't installed — there's nothing to ask.
final hermesVersionServiceProvider = Provider<HermesVersionService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesVersionServiceImpl(path);
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
