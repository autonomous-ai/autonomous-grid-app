import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

void main() {
  group('GridOverview.fromJson', () {
    // The real `GET {relayBaseUrl}/grid/overview` payload.
    const raw = '''
    {
      "grid": {"state": "running"},
      "stats": {"models": 1, "nodes": 1, "concurrent_capacity": 8, "uptime_pct": 99.9},
      "models": [
        {"id": "glm-5.2", "name": "glm-5.2", "maker": null, "modality": "chat",
         "context_length": null,
         "pricing": {"unit": "token", "input_per_1m": 0.0, "output_per_1m": 0.0},
         "status": "available"}
      ],
      "nodes": [
        {"name": "pro60002",
         "device": "NVIDIA RTX PRO 6000 Blackwell Workstation Edition ×4",
         "chip": null, "memory_gb": 96, "vram_gb": 48.0, "vram_total_mb": 49152.0,
         "device_class": "server",
         "model": "glm-5.2", "engine": "External", "plan_type": "free",
         "throughput_tok_s": 52.8, "max_concurrency": 8, "online": true}
      ]
    }''';

    test('parses stats, models and nodes', () {
      final o = GridOverview.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      expect(o.state, 'running');
      expect(o.stats.models, 1);
      expect(o.stats.nodes, 1);
      expect(o.stats.uptimePct, 99.9);

      final m = o.models.single;
      expect(m.id, 'glm-5.2');
      expect(m.modality, 'chat');
      expect(m.pricing?.inputPer1m, 0.0);
      expect(m.pricing?.outputPer1m, 0.0);

      final n = o.nodes.single;
      expect(n.name, 'pro60002');
      expect(n.memoryGb, 96);
      expect(n.vramGb, 48.0);
      expect(n.vramTotalMb, 49152.0);
      expect(n.engine, 'External');
      expect(n.throughputTokS, 52.8);
      expect(n.planType, 'free');
      expect(n.online, isTrue);
    });

    test('tolerates missing sections and null fields', () {
      final o = GridOverview.fromJson(const {});
      expect(o.state, isNull);
      expect(o.stats.models, 0);
      expect(o.models, isEmpty);
      expect(o.nodes, isEmpty);

      final partial = GridOverview.fromJson(const {
        'nodes': [
          {'name': 'n1', 'online': false},
        ],
      });
      expect(partial.nodes.single.online, isFalse);
      expect(partial.nodes.single.device, isNull);
      expect(partial.nodes.single.throughputTokS, isNull);
      expect(partial.nodes.single.planType, isNull);
    });

    test('reads the wire-dialect flags the relay advertises', () {
      final o = GridOverview.fromJson(const {
        'advertises_chat_completions': true,
        'advertises_responses': false,
      });
      expect(o.advertisesChatCompletions, isTrue);
      expect(o.advertisesResponses, isFalse);
    });

    test('a relay that omits the dialect flags reads as unknown, not "no"', () {
      // Every relay predating the flags leaves them out. Parsing absence as
      // `false` would tell the app no grid can run Codex — and would strand a
      // user on a grid that serves it perfectly well.
      final o = GridOverview.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(o.advertisesChatCompletions, isNull);
      expect(o.advertisesResponses, isNull);
    });

    test('a non-boolean flag reads as unknown rather than throwing', () {
      final o = GridOverview.fromJson(const {'advertises_responses': 'true'});
      expect(o.advertisesResponses, isNull);
    });
  });
}
