import 'dart:ffi' show Abi;
import 'dart:io';

import 'macho_arch.dart';

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
/// The bundled sidecar is a Nuitka standalone (onedir) folder built by grid-app's
/// own `scripts/cli/build_sidecar.{sh,ps1}` and injected into the app bundle at
/// packaging time; we compute where it sits from [Platform.resolvedExecutable].
class GridResolver {
  GridResolver({this.configuredPath, String? Function()? pathLookup})
    : _pathLookup = pathLookup ?? _resolveFromSystem;

  /// Path the user pinned in settings, if any.
  final String? configuredPath;

  final String? Function() _pathLookup;

  /// Absolute path to a usable `grid`, or null if none is found.
  String? resolve() {
    // A pinned path (settings / GRID_BIN) is the user's explicit choice — take it
    // as given, don't second-guess its architecture.
    for (final candidate in _pinnedCandidates()) {
      final path = _usablePath(candidate);
      if (path != null) return path;
    }
    // The bundled sidecar is ours to vouch for: skip one this CPU can't execute
    // (an arm64 build shipped to an Intel Mac) so resolution falls through to a
    // working system install instead of shadowing it with a binary that spawns
    // as "Bad CPU type in executable".
    for (final candidate in _bundledCandidates()) {
      final path = _usablePath(candidate);
      if (path != null && _runnableHere(path)) return path;
    }
    return _pathLookup();
  }

  /// The absolute path of [candidate] when it's a real, executable, non-self
  /// file — else null (skip it).
  String? _usablePath(String? candidate) {
    if (candidate == null || candidate.isEmpty) return null;
    final file = File(candidate);
    if (!_isExecutableFile(file) || _isSelf(file)) return null;
    return file.absolute.path;
  }

  /// Whether the binary at [path] can run on this CPU. Only ever answers "no"
  /// for a macOS Intel host holding an arm64-only sidecar; every other case
  /// (Apple Silicon runs both via Rosetta, an unreadable/foreign header) falls
  /// open so we never reject a binary that would have worked.
  static bool _runnableHere(String path) {
    if (!Platform.isMacOS) return true;
    if (Abi.current() != Abi.macosX64) return true;
    return machoRunsOnIntel(_readHeader(File(path))) ?? true;
  }

  /// The leading bytes of [file] — enough to cover a fat header with a handful of
  /// slices — or empty when it can't be read (then [_runnableHere] falls open).
  static List<int> _readHeader(File file) {
    RandomAccessFile? raf;
    try {
      raf = file.openSync();
      return raf.readSync(4096);
    } on FileSystemException {
      return const [];
    } finally {
      raf?.closeSync();
    }
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

  /// Explicitly-pinned paths, tried before the bundled sidecar: a settings
  /// override, then the `GRID_BIN` dev/CI escape hatch.
  Iterable<String?> _pinnedCandidates() sync* {
    yield configuredPath;
    yield Platform.environment['GRID_BIN'];
  }

  /// Where a bundled sidecar lands per platform, relative to the app binary.
  Iterable<String> _bundledCandidates() sync* {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final exe = Platform.isWindows ? 'grid.exe' : 'grid';
    if (Platform.isMacOS) {
      // Grid.app/Contents/MacOS/Grid → the sidecar under Contents/Resources. We
      // ship it as a Nuitka **standalone (onedir)** folder at Resources/grid/grid
      // so macOS never extracts unsigned code at runtime — an --onefile sidecar's
      // extracted payload is SIGKILL'd by Gatekeeper under download quarantine
      // (preflight then shows "Grid helper blocked"). The bare Resources/grid
      // path stays as a fallback for older onefile bundles.
      // Never probe Contents/MacOS — the app binary "Grid" matches "grid" on a
      // case-insensitive filesystem, so we'd resolve (and spawn) the app itself.
      yield '$exeDir/../Resources/grid/$exe';
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
