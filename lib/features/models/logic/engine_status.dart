import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/host_environment.dart';

/// Whether the llama.cpp engine (`llama-server`) is installed for the client.
class EngineStatus {
  const EngineStatus({required this.llamaInstalled, this.llamaPath});

  final bool llamaInstalled;
  final String? llamaPath;

  static const notInstalled = EngineStatus(llamaInstalled: false);
}

/// Detects the engine the same way the CLI locates it: the `LLAMA_SERVER`
/// override, else the linked binary at `~/.grid/bin/llama-server`
/// (provider_runtime installer links it there). [exists] is injectable so the
/// detection is testable without touching the real filesystem.
class EngineDetector {
  EngineDetector({bool Function(String path)? exists})
      : _exists = exists ?? _fileExists;

  final bool Function(String path) _exists;

  EngineStatus detect() {
    final override = Platform.environment['LLAMA_SERVER'];
    if (override != null && override.isNotEmpty && _exists(override)) {
      return EngineStatus(llamaInstalled: true, llamaPath: override);
    }
    final linked = GridPaths.llamaServerBin.path;
    if (_exists(linked)) {
      return EngineStatus(llamaInstalled: true, llamaPath: linked);
    }
    return EngineStatus.notInstalled;
  }

  // existsSync follows symlinks, so a dangling link (broken install) reads as
  // not installed — which is what we want.
  static bool _fileExists(String path) => File(path).existsSync();
}

/// Detected engine status. Invalidate after an install to rescan.
final engineStatusProvider =
    Provider<EngineStatus>((ref) => EngineDetector().detect());

/// Whether Homebrew is installed on this computer (either prefix). The built-in
/// engine's macOS install path drives Homebrew, so the setup checklist gates the
/// engine step on this. Invalidate after installing Homebrew to re-probe.
/// [HostEnvironment] already lists both brew prefixes, so a freshly installed
/// `/opt/homebrew/bin/brew` is seen without rebuilding `PATH`.
final homebrewInstalledProvider =
    Provider<bool>((ref) => HostEnvironment.findExecutable('brew') != null);
