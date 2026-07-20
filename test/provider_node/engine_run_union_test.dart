import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';

void main() {
  group('EngineRunRecord union parsing', () {
    test('reads each engine in the union and classifies its kind', () {
      // The shape the CLI writes for a machine serving three engines at once
      // (ADR 0010): a local GGUF, a hosted API, and an external server.
      final record = EngineRunRecord.fromJson({
        'engine_id': 'remote',
        'grid_id': 'grid-1',
        'pid': 4242,
        'endpoint_port': 52548,
        'models': ['Qwen3.6-35B.gguf', 'codex:gpt-5.5'],
        'engines': [
          {
            'models': ['Qwen3.6-35B.gguf'],
          },
          {
            'models': ['codex:gpt-5.5'],
            'api_kind': 'codex',
          },
          {
            'models': ['llama3.2'],
            'endpoint_url': 'http://localhost:11434/v1',
          },
        ],
      });

      expect(record.engines, hasLength(3));
      expect(record.endpointPort, 52548);

      final local = record.engines[0];
      expect(local.kind, EngineKind.local);
      // A local engine is dropped by a served model.
      expect(local.leaveSelector, 'Qwen3.6-35B.gguf');

      final api = record.engines[1];
      expect(api.kind, EngineKind.api);
      expect(api.apiKind, 'codex');
      expect(api.leaveSelector, 'codex:gpt-5.5');

      final external = record.engines[2];
      expect(external.kind, EngineKind.external);
      // An external engine is dropped by its exact endpoint URL.
      expect(external.leaveSelector, 'http://localhost:11434/v1');
    });

    test('synthesizes a single engine from flat fields when engines[] is '
        'absent (an older record)', () {
      final record = EngineRunRecord.fromJson({
        'engine_id': 'remote',
        'grid_id': 'grid-1',
        'pid': 7,
        'models': ['gpt-5.5'],
        'api_kind': 'openai',
      });

      expect(record.engines, hasLength(1));
      expect(record.engines.single.kind, EngineKind.api);
      expect(record.engines.single.apiKind, 'openai');
    });

    test('a malformed record degrades to empty rather than throwing', () {
      final record = EngineRunRecord.fromJson({'engine_id': 'remote'});
      expect(record.models, isEmpty);
      expect(record.pid, isNull);
      // The synthesized fallback spec has no models, so the UI drops it.
      expect(record.engines.single.models, isEmpty);
    });
  });
}
