import 'dart:io';

/// Locates the `grid` executable. Resolution order:
///   1. an explicit user-configured path (settings),
///   2. the `GRID_BIN` env var (dev/CI escape hatch),
///   3. a sidecar bundled inside the app (shipped with the installer),
///   4. the system: well-known install dirs, then a login shell.
///
/// macOS GUI apps do **not** inherit the shell's `PATH` — a `uv tool install`ed
/// `grid` lives in `~/.local/bin`, which a Finder/`open`-launched app cannot see
/// via a bare `which`. So step 4 probes the usual install dirs directly and, as
/// a last resort, asks a login shell (which loads the user's profile).
///
/// The bundled sidecar is a Nuitka onefile binary built by the CLI repo's
/// `build/build_{macos,linux,windows}` scripts and injected next to the app at
/// packaging time; we compute where it sits from [Platform.resolvedExecutable].
class GridResolver {
  GridResolver({this.configuredPath, String? Function()? pathLookup})
      : _pathLookup = pathLookup ?? _resolveFromSystem;

  /// Path the user pinned in settings, if any.
  final String? configuredPath;

  final String? Function() _pathLookup;

  /// Absolute path to a usable `grid`, or null if none is found.
  String? resolve() {
    for (final candidate in _explicitCandidates()) {
      if (candidate == null || candidate.isEmpty) continue;
      final file = File(candidate);
      if (!_isExecutableFile(file) || _isSelf(file)) continue;
      return file.absolute.path;
    }
    return _pathLookup();
  }

  /// True when [file] is the running app's own executable. Guards against
  /// resolving — and then spawning — the app instead of the CLI: the macOS app
  /// binary is "Grid", which a case-insensitive filesystem also matches as
  /// "grid", so a naive probe of `Contents/MacOS` would launch the app itself.
  static bool _isSelf(File file) {
    try {
      return file.resolveSymbolicLinksSync() ==
          File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  Iterable<String?> _explicitCandidates() sync* {
    yield configuredPath;
    yield Platform.environment['GRID_BIN'];
    yield* _bundledCandidates();
  }

  /// Where a bundled sidecar lands per platform, relative to the app binary.
  Iterable<String> _bundledCandidates() sync* {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final exe = Platform.isWindows ? 'grid.exe' : 'grid';
    if (Platform.isMacOS) {
      // Grid.app/Contents/MacOS/Grid → Contents/Resources/grid. Stop here: never
      // probe Contents/MacOS — the app binary "Grid" matches "grid" on a
      // case-insensitive filesystem, so we'd resolve (and spawn) the app itself.
      yield '$exeDir/../Resources/$exe';
      return;
    }
    // Linux/Windows: next to the executable, or in a `grid/` subfolder.
    yield '$exeDir/$exe';
    yield '$exeDir/grid/$exe';
  }

  /// Default lookup when no explicit path is given. Probes well-known dirs
  /// (independent of the inherited PATH), then falls back to a login shell.
  static String? _resolveFromSystem() {
    if (Platform.isWindows) return _whichWindows();

    final home = Platform.environment['HOME'] ?? '';
    final wellKnown = <String>[
      if (home.isNotEmpty) '$home/.local/bin/grid', // uv tool / pipx
      '/opt/homebrew/bin/grid', // Homebrew (Apple Silicon)
      '/usr/bin/grid',
    ];
    for (final path in wellKnown) {
      final file = File(path);
      if (_isExecutableFile(file)) return file.absolute.path;
    }
    return _viaLoginShell();
  }

  /// Last resort: a login shell loads the user's profile, so `PATH` includes
  /// custom install dirs. `-l` (login), no `-i`, to avoid interactive hangs.
  static String? _viaLoginShell() {
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    try {
      final result = Process.runSync(shell, ['-lc', 'command -v grid']);
      if (result.exitCode != 0) return null;
      for (final raw in (result.stdout as String).split('\n')) {
        final line = raw.trim();
        if (!line.startsWith('/')) continue;
        final file = File(line);
        if (_isExecutableFile(file)) return file.absolute.path;
      }
      return null;
    } on ProcessException {
      return null;
    }
  }

  static String? _whichWindows() {
    try {
      final result = Process.runSync('where', ['grid']);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      return out.isEmpty ? null : out.split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }

  static bool _isExecutableFile(File file) {
    if (!file.existsSync()) return false;
    if (Platform.isWindows) return true;
    return file.statSync().mode & 0x49 != 0; // any of the execute bits (0o111)
  }
}
