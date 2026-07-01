import 'dart:convert';

/// The context window a local GGUF model supports, parsed from
/// `grid ctx --json <model>` — e.g.
/// `{"file": "/…/Qwen3.6-35B-A3B-UD-IQ3_S.gguf", "context_length": 262144}`.
///
/// Used to bound the context-length slider before starting the built-in engine
/// so the user can never ask for more context than the model was trained for.
class ModelContext {
  const ModelContext({required this.file, required this.contextLength});

  /// Absolute path to the GGUF the CLI inspected.
  final String file;

  /// Maximum context length in tokens the model supports.
  final int contextLength;

  /// Parse one `grid ctx --json` payload. Returns null when the output isn't the
  /// expected JSON object or the context length is missing/non-positive — the
  /// caller then falls back to the engine's own default context.
  static ModelContext? parse(String jsonOutput) {
    final trimmed = jsonOutput.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      final length = decoded['context_length'];
      if (length is! int || length <= 0) return null;
      final file = decoded['file'];
      return ModelContext(
        file: file is String ? file : '',
        contextLength: length,
      );
    } on FormatException {
      return null;
    }
  }
}
