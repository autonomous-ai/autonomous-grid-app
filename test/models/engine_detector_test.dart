import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';

void main() {
  test('detects the linked llama-server', () {
    final detector = EngineDetector(
      exists: (p) => p.endsWith('/bin/llama-server'),
    );
    final status = detector.detect();
    expect(status.llamaInstalled, isTrue);
    expect(status.llamaPath, contains('/bin/llama-server'));
  });

  test('reports not installed when nothing is present', () {
    final detector = EngineDetector(exists: (_) => false);
    expect(detector.detect().llamaInstalled, isFalse);
    expect(detector.detect().llamaPath, isNull);
  });
}
