import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/backend_detector.dart';

void main() {
  test('detects a running Ollama and the grid llama.cpp engine', () async {
    final detector = BackendDetector(
      probeModels: (url) async =>
          url.contains('11434') ? ['gemma:7b', 'llama3'] : null,
      fileExists: (p) => p.endsWith('/bin/llama-server'),
    );

    final found = await detector.detect();

    final ollama = found.firstWhere((b) => b.kind == BackendKind.ollama);
    expect(ollama.baseUrl, 'http://localhost:11434/v1');
    expect(ollama.models, ['gemma:7b', 'llama3']);
    expect(found.any((b) => b.kind == BackendKind.llamaCpp), isTrue);
    expect(found.any((b) => b.kind == BackendKind.lmStudio), isFalse);
  });

  test('detects nothing when nothing is present', () async {
    final detector = BackendDetector(
      probeModels: (_) async => null,
      fileExists: (_) => false,
    );
    expect(await detector.detect(), isEmpty);
  });
}
