import 'dart:io';

/// Signature for handing a downloaded installer to the OS. Injected via
/// [installerLauncherProvider] so the controller stays unit-testable (the real
/// [launchInstaller] spawns platform processes; tests swap in a no-op).
typedef InstallerLauncher = Future<void> Function(File file);

/// Opens a downloaded installer so the user can complete the update. Each
/// desktop delivers updates differently:
///   * macOS   — `open` the `.dmg`/`.pkg`; Gatekeeper verifies the signature.
///   * Windows — run the `.exe`/`.msi` setup detached; the app then quits so it
///     can be replaced.
///   * Linux   — mark an `.AppImage` executable and launch it, else `xdg-open`.
/// Throws on failure so the controller can fall back to a manual-download prompt.
Future<void> launchInstaller(File file) async {
  final path = file.path;

  if (Platform.isMacOS) {
    await _run('open', [path]);
    return;
  }
  if (Platform.isWindows) {
    await Process.start(path, const [], mode: ProcessStartMode.detached);
    return;
  }
  if (Platform.isLinux) {
    if (path.toLowerCase().endsWith('.appimage')) {
      await _run('chmod', ['+x', path]);
      await Process.start(path, const [], mode: ProcessStartMode.detached);
      return;
    }
    await _run('xdg-open', [path]);
    return;
  }

  throw UnsupportedError('Auto-update is not supported on this platform.');
}

Future<void> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}
