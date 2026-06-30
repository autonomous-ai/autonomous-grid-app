import 'dart:convert';
import 'dart:io';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/host_environment.dart';

enum BackendKind { ollama, lmStudio, llamaCpp }

/// An inference backend found on the machine that a provider can serve from.
class DetectedBackend {
  const DetectedBackend({
    required this.kind,
    required this.label,
    required this.baseUrl,
    this.models = const [],
    this.running = true,
  });

  final BackendKind kind;
  final String label;

  /// OpenAI-compatible base URL to pass to `grid join --at`.
  /// Empty for llama.cpp (it has no running server until a provider starts it).
  final String baseUrl;
  final List<String> models;

  /// Whether the backend's server is actually answering. False for one that's
  /// installed but not started yet (e.g. Ollama detected on disk but not serving)
  /// — the UI offers to start it instead of a serve form.
  final bool running;

  bool get isExternal => baseUrl.isNotEmpty;
}

/// Probes for existing OpenAI-compatible servers (Ollama, LM Studio) and the
/// grid-managed llama.cpp engine. HTTP probing, the file check, and the
/// executable lookup are injectable so detection is testable offline.
class BackendDetector {
  BackendDetector({
    Future<List<String>?> Function(String baseUrl)? probeModels,
    bool Function(String path)? fileExists,
    bool Function(String name)? hasExecutable,
  })  : _probeModels = probeModels ?? _httpProbeModels,
        _fileExists = fileExists ?? _defaultFileExists,
        _hasExecutable = hasExecutable ?? _defaultHasExecutable;

  final Future<List<String>?> Function(String baseUrl) _probeModels;
  final bool Function(String path) _fileExists;
  final bool Function(String name) _hasExecutable;

  static const _ollamaBase = 'http://localhost:11434/v1';
  static const _lmStudioBase = 'http://localhost:1234/v1';

  Future<List<DetectedBackend>> detect() async {
    final found = <DetectedBackend>[];

    final ollama = await _probeModels(_ollamaBase);
    if (ollama != null) {
      found.add(DetectedBackend(
        kind: BackendKind.ollama,
        label: 'Ollama',
        baseUrl: _ollamaBase,
        models: ollama,
      ));
    } else if (_hasExecutable('ollama')) {
      // Installed but not serving yet — surface it so the user can start it from
      // the app (the "Run Ollama" button) instead of it looking absent.
      found.add(const DetectedBackend(
        kind: BackendKind.ollama,
        label: 'Ollama',
        baseUrl: _ollamaBase,
        running: false,
      ));
    }

    final lmStudio = await _probeModels(_lmStudioBase);
    if (lmStudio != null) {
      found.add(DetectedBackend(
        kind: BackendKind.lmStudio,
        label: 'LM Studio',
        baseUrl: _lmStudioBase,
        models: lmStudio,
      ));
    }

    if (_fileExists(GridPaths.llamaServerBin.path)) {
      found.add(const DetectedBackend(
        kind: BackendKind.llamaCpp,
        label: 'llama.cpp (grid)',
        baseUrl: '',
      ));
    }

    return found;
  }

  /// Best-effort: is an OpenAI-compatible server answering at [baseUrl]? Used to
  /// poll for a backend coming online after we start it.
  static Future<bool> isServerUp(String baseUrl) async =>
      (await _httpProbeModels(baseUrl)) != null;

  /// Absolute path to executable [name] on the augmented host PATH, or null when
  /// it isn't installed. Uses [HostEnvironment.path] so a packaged GUI app finds
  /// Homebrew/login-shell tools its minimal PATH would otherwise miss.
  static String? findOnPath(String name) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    for (final dir in HostEnvironment.path().split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final file = File('$dir${Platform.pathSeparator}$exe');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  /// GET `{baseUrl}/models` and return the model ids, or null if unreachable.
  static Future<List<String>?> _httpProbeModels(String baseUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(Uri.parse('$baseUrl/models'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['data'] is! List) return const [];
      return (decoded['data'] as List)
          .whereType<Map>()
          .map((m) => '${m['id']}')
          .toList();
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static bool _defaultFileExists(String path) => File(path).existsSync();

  /// Whether command-line tool [name] is installed — on PATH, or (macOS) shipped
  /// inside its `/Applications/<Name>.app` bundle, which the user may run without
  /// the CLI ever being on PATH.
  static bool _defaultHasExecutable(String name) {
    if (findOnPath(name) != null) return true;
    if (Platform.isMacOS) {
      final app = '${name[0].toUpperCase()}${name.substring(1)}';
      return Directory('/Applications/$app.app').existsSync();
    }
    return false;
  }
}
