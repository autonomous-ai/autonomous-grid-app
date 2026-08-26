/// Where a machine keeps a user-installed `grid`, for a GUI app that inherits
/// none of the shell's `PATH`.
///
/// Split from [GridResolver] because it answers a different question: the
/// resolver decides *which* binary to use, this one knows where an OS puts
/// them — well-known install dirs first (a Finder-launched app can't see
/// `~/.local/bin` via a bare `which`), then a login shell that loads the user's
/// profile.
library;

import 'dart:io';

/// Default lookup when no explicit path is given. Probes well-known dirs
/// (independent of the inherited PATH), then falls back to a login shell.
String? resolveGridFromSystem() {
  if (Platform.isWindows) return _whichWindows();

  final home = Platform.environment['HOME'] ?? '';
  final wellKnown = <String>[
    if (home.isNotEmpty) '$home/.local/bin/grid', // uv tool / pipx
    '/opt/homebrew/bin/grid', // Homebrew (Apple Silicon)
    '/usr/local/bin/grid', // Homebrew (Intel) / a manual install
    '/usr/bin/grid',
  ];
  for (final path in wellKnown) {
    final file = File(path);
    if (isExecutableFile(file)) return file.absolute.path;
  }
  return _viaLoginShell();
}

/// Last resort: a login shell loads the user's profile, so `PATH` includes
/// custom install dirs. `-l` (login), no `-i`, to avoid interactive hangs.
String? _viaLoginShell() {
  final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
  try {
    final result = Process.runSync(shell, ['-lc', 'command -v grid']);
    if (result.exitCode != 0) return null;
    for (final raw in (result.stdout as String).split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('/')) continue;
      final file = File(line);
      if (isExecutableFile(file)) return file.absolute.path;
    }
    return null;
  } on ProcessException {
    return null;
  }
}

String? _whichWindows() {
  try {
    final result = Process.runSync('where', ['grid']);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out.split('\n').first.trim();
  } on ProcessException {
    return null;
  }
}

/// Whether [file] exists and carries an execute bit — the cheap check that
/// keeps a directory, a missing path or a plain data file out of the candidate
/// list before anything tries to spawn it. Always true on Windows, which has no
/// execute bit.
bool isExecutableFile(File file) {
  if (!file.existsSync()) return false;
  if (Platform.isWindows) return true;
  return file.statSync().mode & 0x49 != 0; // any of the execute bits (0o111)
}
