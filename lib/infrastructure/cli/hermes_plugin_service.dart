import 'dart:io';

import 'host_environment.dart';

/// Raised when a `hermes plugins` command fails, carrying the line the CLI
/// printed so the controller can show it instead of inventing a message.
class HermesPluginException implements Exception {
  const HermesPluginException(this.message);

  final String message;

  @override
  String toString() => 'HermesPluginException: $message';
}

/// The seam onto Hermes's plugin manager (`hermes plugins`).
///
/// Plugins are whole tool backends (a browser, a search provider) shipped with
/// Hermes or pulled from a Git repo. Hermes owns installing and enabling them;
/// the app just drives the CLI and reads its JSON back, so the screen can never
/// disagree with what the agent will actually load.
abstract interface class HermesPluginService {
  /// Every plugin Hermes knows about, as the JSON `plugins list --json` prints.
  Future<String> listJson();

  /// Install from a Git URL or `owner/repo`, enabled and ready to use.
  Future<void> install(String identifier);

  Future<void> enable(String name);
  Future<void> disable(String name);
  Future<void> remove(String name);
}

/// Real implementation: spawns the `hermes` binary.
class HermesPluginServiceImpl implements HermesPluginService {
  const HermesPluginServiceImpl(this.binPath);

  /// Absolute path to the hermes binary (it isn't on a GUI app's default PATH).
  final String binPath;

  @override
  Future<String> listJson() => _run(['plugins', 'list', '--json']);

  @override
  Future<void> install(String identifier) async {
    // --enable: the user asked for the plugin, so installing it disabled (and
    // making them find a second switch) would just be a trap.
    await _run(['plugins', 'install', identifier, '--enable']);
  }

  @override
  Future<void> enable(String name) async {
    await _run(['plugins', 'enable', name]);
  }

  @override
  Future<void> disable(String name) async {
    await _run(['plugins', 'disable', name]);
  }

  @override
  Future<void> remove(String name) async {
    await _run(['plugins', 'remove', name]);
  }

  Future<String> _run(List<String> args) async {
    final result = await Process.run(
      binPath,
      args,
      environment: HostEnvironment.hermesEnvironment(),
    );
    final stdout = (result.stdout as String).trim();
    if (result.exitCode == 0) return stdout;
    final stderr = (result.stderr as String).trim();
    throw HermesPluginException(stderr.isNotEmpty ? stderr : stdout);
  }
}
