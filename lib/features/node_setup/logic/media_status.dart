import '../../../infrastructure/cli/grid_cli_service.dart';

/// Presence of one ComfyUI media model bundle (e.g. `image_generation`), read
/// from a `Bundle <name>  X/Y files present` line of `grid engine status`.
class MediaBundleStatus {
  const MediaBundleStatus({
    required this.name,
    required this.filesPresent,
    required this.filesTotal,
  });

  final String name;
  final int filesPresent;
  final int filesTotal;

  bool get isComplete => filesTotal > 0 && filesPresent >= filesTotal;
}

/// ComfyUI install + runtime status, parsed from `grid engine status`. The CLI
/// is the source of truth (cli/engine.py:cmd_engine_status); we read its printed
/// lines rather than probing ComfyUI's port ourselves.
class MediaStatus {
  const MediaStatus({
    required this.installed,
    required this.running,
    this.bundles = const [],
  });

  final bool installed;
  final bool running;
  final List<MediaBundleStatus> bundles;

  MediaBundleStatus? bundle(String name) {
    for (final b in bundles) {
      if (b.name == name) return b;
    }
    return null;
  }

  static const notInstalled = MediaStatus(installed: false, running: false);
}

/// Runs `grid engine status` and parses its output into a [MediaStatus]. The CLI
/// call is injected via [GridCliService]; on any failure (command absent, media
/// unsupported on this platform, unparseable output) we report "not installed"
/// so the setup flow simply offers to install it.
class MediaDetector {
  const MediaDetector(this._service);

  final GridCliService? _service;

  Future<MediaStatus> detect() async {
    final service = _service;
    if (service == null) return MediaStatus.notInstalled;
    final result = await service.run(const ['engine', 'status']);
    if (!result.ok) return MediaStatus.notInstalled;
    return parseStatus(result.stdout);
  }

  /// Parses the line-oriented `grid engine status` output. Exposed for tests.
  static MediaStatus parseStatus(String stdout) {
    var installed = false;
    var running = false;
    final bundles = <MediaBundleStatus>[];

    for (final raw in stdout.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('Installed')) {
        installed = _yesAfterColon(line);
      } else if (line.startsWith('Running')) {
        running = _yesAfterColon(line);
      } else if (line.startsWith('Bundle ')) {
        final bundle = _parseBundle(line);
        if (bundle != null) bundles.add(bundle);
      }
    }
    return MediaStatus(installed: installed, running: running, bundles: bundles);
  }

  static bool _yesAfterColon(String line) {
    final colon = line.indexOf(':');
    if (colon < 0) return false;
    return line.substring(colon + 1).trimLeft().toLowerCase().startsWith('yes');
  }

  // `Bundle image_generation   3/3 files present`
  static final _bundlePattern = RegExp(r'^Bundle\s+(\S+)\s+(\d+)\s*/\s*(\d+)');

  static MediaBundleStatus? _parseBundle(String line) {
    final m = _bundlePattern.firstMatch(line);
    if (m == null) return null;
    return MediaBundleStatus(
      name: m.group(1)!,
      filesPresent: int.parse(m.group(2)!),
      filesTotal: int.parse(m.group(3)!),
    );
  }
}
