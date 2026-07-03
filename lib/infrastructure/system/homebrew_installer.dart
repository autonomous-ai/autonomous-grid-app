import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cli/grid_cli_service.dart';
import '../cli/host_environment.dart';

/// Installs Homebrew on the user's Mac so the built-in engine can be set up.
///
/// Why: `grid engine install llama.cpp` (the prebuilt Apple-Silicon path) hard
/// depends on Homebrew, which a non-technical user's Mac almost never has. Left
/// alone, node setup dead-ends with a raw "Homebrew is required" error. So we
/// detect the gap and install Homebrew first — streaming a readable log and
/// asking for the admin password through macOS's own native dialog (a GUI app
/// has no terminal, so `sudo` can't prompt on its own).
abstract interface class HomebrewInstaller {
  /// Whether an auto-install is even possible here (macOS only).
  bool get isSupported;

  /// Whether `brew` already resolves on the app's augmented `PATH`.
  bool get isInstalled;

  /// Runs the official Homebrew installer, returning a process handle whose
  /// merged output can be streamed. Success is `exitCode == 0`, which the script
  /// only returns once `brew` is actually resolvable afterwards.
  Future<GridProcess> install();
}

/// Real [HomebrewInstaller] that drives the official install script through a
/// login `bash`, priming `sudo` via a native password prompt.
class SystemHomebrewInstaller implements HomebrewInstaller {
  const SystemHomebrewInstaller();

  /// The canonical, HTTPS-only Homebrew bootstrap script.
  static const _installerUrl =
      'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh';

  @override
  bool get isSupported => Platform.isMacOS;

  @override
  bool get isInstalled => HostEnvironment.findExecutable('brew') != null;

  @override
  Future<GridProcess> install() async {
    final workDir = Directory.systemTemp.createTempSync('grid_brew_');
    final askpass = _writeAskpass(workDir);

    final process = await Process.start(
      '/bin/bash',
      ['-c', _installScript(askpass.path)],
      runInShell: false,
      environment: {'PATH': HostEnvironment.path()},
    );

    final controller = StreamController<CliLine>();
    final outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => controller.add(CliLine(isStderr: false, text: line)),
            onError: controller.addError);
    final errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => controller.add(CliLine(isStderr: true, text: line)),
            onError: controller.addError);

    unawaited(process.exitCode.whenComplete(() async {
      await outSub.cancel();
      await errSub.cancel();
      await controller.close();
      _cleanup(workDir);
    }));

    return GridProcess(
      lines: controller.stream,
      exitCode: process.exitCode,
      kill: () => process.kill(ProcessSignal.sigterm),
    );
  }

  /// A `SUDO_ASKPASS` helper: prints the admin password from macOS's native
  /// secure dialog, or exits non-zero (so `sudo` aborts, no retry) on cancel.
  File _writeAskpass(Directory dir) {
    final file = File('${dir.path}/askpass.sh');
    file.writeAsStringSync(
      '#!/bin/bash\n'
      "exec osascript -e 'text returned of (display dialog "
      '"Grid needs your Mac administrator password to install Homebrew — '
      'the tool that runs the built-in AI engine on this computer." '
      'with title "Grid setup" default answer "" '
      "with hidden answer with icon caution)'\n",
    );
    Process.runSync('chmod', ['700', file.path]);
    return file;
  }

  /// One self-contained script: skip if brew exists, prime `sudo` through the
  /// askpass prompt, keep the timestamp warm while the (TTY-less) installer runs,
  /// then confirm `brew` is really on `PATH` before reporting success.
  String _installScript(String askpassPath) => '''
set -o pipefail
export SUDO_ASKPASS='$askpassPath'

echo "Checking for Homebrew"
if command -v brew >/dev/null 2>&1; then
  echo "Homebrew is already installed"
  exit 0
fi

echo "Homebrew not found - installing (this can take a few minutes)"
echo "Asking for your administrator password"
if ! sudo -A -v; then
  echo "Administrator permission was declined." >&2
  exit 1
fi

# A Finder-launched app has no terminal, so the installer's own sudo calls rely
# on this cached timestamp; refresh it every 30s so it never lapses mid-install.
( while true; do sudo -n -v >/dev/null 2>&1 || exit 0; sleep 30; done ) &
keepalive=\$!

NONINTERACTIVE=1 /bin/bash -c "\$(curl -fsSL $_installerUrl)"
status=\$?
kill "\$keepalive" >/dev/null 2>&1 || true

if [ "\$status" -ne 0 ]; then
  echo "Homebrew installer exited with status \$status" >&2
  exit "\$status"
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew installed but 'brew' was not found on PATH." >&2
  exit 1
fi
echo "Homebrew installed successfully"
exit 0
''';

  void _cleanup(Directory dir) {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Temp cleanup is best-effort; a leftover askpass script is harmless.
    }
  }
}
