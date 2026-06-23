import 'dart:convert';
import 'dart:io';

import '../../../core/grid_paths.dart';

enum BackendKind { ollama, lmStudio, llamaCpp }

/// An inference backend found on the machine that a provider can serve from.
class DetectedBackend {
  const DetectedBackend({
    required this.kind,
    required this.label,
    required this.baseUrl,
    this.models = const [],
  });

  final BackendKind kind;
  final String label;

  /// OpenAI-compatible base URL to pass to `grid provider start --at`.
  /// Empty for llama.cpp (it has no running server until a provider starts it).
  final String baseUrl;
  final List<String> models;

  bool get isExternal => baseUrl.isNotEmpty;
}

/// Probes for existing OpenAI-compatible servers (Ollama, LM Studio) and the
/// grid-managed llama.cpp engine. HTTP probing and the file check are injectable
/// so detection is testable offline.
class BackendDetector {
  BackendDetector({
    Future<List<String>?> Function(String baseUrl)? probeModels,
    bool Function(String path)? fileExists,
  })  : _probeModels = probeModels ?? _httpProbeModels,
        _fileExists = fileExists ?? _defaultFileExists;

  final Future<List<String>?> Function(String baseUrl) _probeModels;
  final bool Function(String path) _fileExists;

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
}
