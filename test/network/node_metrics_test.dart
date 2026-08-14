import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/node_metrics.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

OverviewNode _node({
  String name = 'spark-1',
  double? vramTotalMb,
  double? vramUsedMb,
  double? gpuUtilPct,
  double? gpuTempC,
  double? gpuPowerW,
  double? gpuPowerLimitW,
  double? diskTotalGb,
  double? diskUsedGb,
  double? throughputTokS,
  String? platform,
}) => OverviewNode(
  name: name,
  online: true,
  platform: platform,
  vramTotalMb: vramTotalMb,
  vramUsedMb: vramUsedMb,
  gpuUtilPct: gpuUtilPct,
  gpuTempC: gpuTempC,
  gpuPowerW: gpuPowerW,
  gpuPowerLimitW: gpuPowerLimitW,
  diskTotalGb: diskTotalGb,
  diskUsedGb: diskUsedGb,
  throughputTokS: throughputTokS,
);

void main() {
  group('a reading the node never sent still gets its row', () {
    test(
      'every card draws the same three bars, whatever the machine reported',
      () {
        // Rows that come and go make two machines impossible to compare — the eye
        // has to re-read the labels on each card before it can read the numbers.
        final bare = _node();
        final full = _node(
          vramTotalMb: 124620,
          vramUsedMb: 100556,
          gpuTempC: 53,
          gpuUtilPct: 98,
        );

        expect(
          nodeBars(bare).map((m) => m.label),
          nodeBars(full).map((m) => m.label),
        );
        expect(nodeBars(bare).every((m) => m.measured), isFalse);
        expect(nodeBars(full).every((m) => m.measured), isTrue);
      },
    );

    test('an unreported reading is dashed and dashless, never a zero', () {
      // `measured: false` is what makes the card draw a broken line instead of
      // an empty track, and an empty track is exactly what a real 0% looks like.
      final metric = temperatureMetric(_node());

      expect(metric.value, kUnmeasured);
      expect(metric.measured, isFalse);
      expect(metric.fraction, isNull);
    });

    test('a genuine zero stays a measured reading', () {
      // The distinction the whole file turns on: 0% means "measured, and this
      // node is doing nothing right now".
      final idle = usageMetric(_node(gpuUtilPct: 0));

      expect(idle.value, '0%');
      expect(idle.measured, isTrue);
      expect(idle.fraction, 0.0);
    });

    test('a half-known pair keeps the half it knows', () {
      // The total is the pool a model must fit into — a real fact, worth showing
      // even when nothing measured how much of it is busy.
      final metric = memoryMetric(_node(vramTotalMb: 65536));

      expect(metric.value, '$kUnmeasured / 64 GB');
      expect(metric.measured, isFalse);
    });

    test('a card with no power cap still shows the draw it measured', () {
      // macOS publishes watts drawn but no ceiling, and inventing one from a
      // spec sheet would draw a bar whose denominator nothing measured.
      final metric = powerMetric(_node(gpuPowerW: 22));

      expect(metric.value, '22W / $kUnmeasured');
      expect(metric.measured, isFalse);
    });

    test('a node that has served nothing reports no throughput', () {
      expect(throughputLabel(_node()), kUnmeasured);
      expect(throughputLabel(_node(throughputTokS: 0)), kUnmeasured);
      expect(throughputLabel(_node(throughputTokS: 248.7)), '249');
    });
  });

  group('an Apple Silicon machine has RAM, not VRAM', () {
    test('unified memory is named for what it is', () {
      // Its GPU shares one pool with the CPU — which is why the provider
      // advertises `hw.memsize` as its memory. Calling that "VRAM" invites the
      // reader to look for a graphics card that does not exist, and to misread
      // 64 GB as dedicated when it is the whole machine's memory.
      expect(memoryLabel(_node(platform: 'macos-arm64')), 'RAM');
      expect(memoryMetric(_node(platform: 'macos-arm64')).label, 'RAM');
    });

    test('every other machine keeps VRAM', () {
      expect(memoryLabel(_node(platform: 'linux')), 'VRAM');
      expect(memoryLabel(_node(platform: 'macos-x86_64')), 'VRAM');
      expect(memoryLabel(_node()), 'VRAM'); // platform absent — assume a card
    });
  });

  group('figures read the way an operator expects them', () {
    test('memory pairs used against total', () {
      final metric = memoryMetric(
        _node(vramTotalMb: 124620, vramUsedMb: 100556),
      );

      expect(metric.value, '98.2 / 121.7 GB');
      expect(metric.fraction, closeTo(0.807, 0.001));
    });

    test('a whole number drops its decimal, a fractional one keeps it', () {
      // A 3755 GB drive should not read "3755.0 GB" beside a "541.4".
      expect(formatMetricNumber(3755), '3755');
      expect(formatMetricNumber(541.44), '541.4');
    });

    test('power shows the draw against the card cap', () {
      final metric = powerMetric(_node(gpuPowerW: 894.8, gpuPowerLimitW: 2400));

      expect(metric.value, '894.8W / 2400W');
      expect(metric.fraction, closeTo(0.373, 0.001));
    });

    test('storage pairs used against the volume total', () {
      final metric = storageMetric(_node(diskTotalGb: 3755, diskUsedGb: 541.4));

      expect(metric.value, '541.4 / 3755 GB');
    });

    test('free memory is only derived when both sides were measured', () {
      expect(
        freeMemoryLabel(_node(vramTotalMb: 124620, vramUsedMb: 111206)),
        '13.1 GB',
      );
      expect(freeMemoryLabel(_node(vramTotalMb: 124620)), kUnmeasured);
    });
  });

  group('bars never overflow their track', () {
    test('a provider reporting past its own ceiling pins at full', () {
      // A bad reading should make the card look pinned, not break its layout.
      expect(usageMetric(_node(gpuUtilPct: 140)).fraction, 1.0);
      expect(
        memoryMetric(_node(vramTotalMb: 1024, vramUsedMb: 4096)).fraction,
        1.0,
      );
    });

    test(
      'tone rises with the reading so a busy node is spottable at a glance',
      () {
        expect(usageMetric(_node(gpuUtilPct: 12)).tone, MetricTone.calm);
        expect(usageMetric(_node(gpuUtilPct: 70)).tone, MetricTone.warm);
        expect(usageMetric(_node(gpuUtilPct: 95)).tone, MetricTone.hot);
      },
    );
  });

  group('what a node has answered', () {
    test(
      'a relay that reported nothing is unmeasured, not an idle machine',
      () {
        // The distinction this whole file exists to protect. An older master
        // computes no such figure, and printing `0` there would tell a person
        // their machine served nobody today.
        final silent = _node();
        expect(answeredTokensMetric(silent).measured, isFalse);
        expect(answeredTokensMetric(silent).value, kUnmeasured);
        expect(answeredRequestsMetric(silent).measured, isFalse);
      },
    );

    test('cached input is a share of input, never a fourth bucket', () {
      // The relay bills `(in − cached)·input + cached·cache + out·output`, so
      // the three legs a card draws must be fresh-input / cache / output. Using
      // `tokensIn` raw would print three figures that add up to more than the
      // machine handled — and the error grows with how well the cache works.
      final node = _answering(
        tokensIn: 1000,
        tokensCached: 400,
        tokensOut: 150,
      );
      final answered = node.answered!;

      expect(answered.freshInputTokens, 600);
      expect(answered.totalTokens, 1150); // in + out, NOT in + cached + out
      expect(
        answered.freshInputTokens + answered.tokensCached + answered.tokensOut,
        answered.totalTokens,
      );
      expect(answeredInputMetric(node).value, '600');
      expect(answeredCachedMetric(node).value, '400');
      expect(answeredTokensMetric(node).value, '150');
    });

    test('a grid with no cache hits still shows every leg', () {
      // A zero cache row is a fact about the grid worth seeing; dropping it
      // would make the remaining rows look like the whole story.
      final node = _answering(tokensIn: 800, tokensOut: 200);

      expect(answeredCachedMetric(node).measured, isTrue);
      expect(answeredCachedMetric(node).value, '0');
      expect(answeredInputMetric(node).value, '800');
    });

    test('input and cache are unmeasured when the relay reported nothing', () {
      expect(answeredInputMetric(_node()).measured, isFalse);
      expect(answeredCachedMetric(_node()).measured, isFalse);
    });

    test('a machine measured and found idle prints a real zero', () {
      final idle = _answering(tokensOut: 0, requests: 0);
      expect(answeredTokensMetric(idle).measured, isTrue);
      expect(answeredTokensMetric(idle).value, '0');
    });

    test('counts shorten so two cards stay comparable at a glance', () {
      // A busy node and a quiet one are six orders of magnitude apart, and the
      // column is sized for "59.4 GB".
      expect(formatCount(0), '0');
      expect(formatCount(940), '940');
      expect(formatCount(1500), '1.5K');
      expect(formatCount(12300), '12.3K');
      expect(formatCount(180000), '180K');
      expect(formatCount(1000000), '1M');
      expect(formatCount(1240000), '1.2M');
      expect(formatCount(12400000), '12.4M');
    });

    test('the label names the span the relay actually counted', () {
      // Hardcoding "24h" would go quietly wrong the moment an operator retuned
      // NODE_ANSWERED_WINDOW_SECONDS, and a dashboard must not be wrong that way.
      expect(answeredWindowLabel(86400), '24h');
      expect(answeredWindowLabel(604800), '7d');
      expect(answeredWindowLabel(21600), '6h');
      expect(answeredWindowLabel(1800), '30m');
      expect(
        answeredTokensMetric(
          _answering(tokensOut: 5, windowSeconds: 21600),
        ).label,
        'Output · 6h',
      );
    });

    test('a relay that sent no window leaves no dangling separator', () {
      expect(
        answeredTokensMetric(_answering(tokensOut: 5, windowSeconds: 0)).label,
        'Output',
      );
    });

    test('the per-model split is offered only where the totals hide one', () {
      // One model's total IS the node's total, and the card already prints its
      // name in its own field — a hint repeating that earns nothing.
      expect(
        answeredByModelHint(
          _answering(
            tokensOut: 300,
            byModel: const [
              AnsweredModel(model: 'glm-4.6', tokensOut: 300, requests: 4),
            ],
          ),
        ),
        isEmpty,
      );
      expect(
        answeredByModelHint(
          _answering(
            tokensOut: 1420000,
            byModel: const [
              AnsweredModel(
                model: 'glm-4.6',
                tokensOut: 1240000,
                requests: 340,
              ),
              AnsweredModel(model: 'qwen3', tokensOut: 180000, requests: 22),
            ],
          ),
        ),
        'glm-4.6 — 1.2M output tokens · 340 requests\n'
        'qwen3 — 180K output tokens · 22 requests',
      );
    });
  });
}

/// A node whose relay reported an answered rollup.
OverviewNode _answering({
  int tokensIn = 0,
  int tokensCached = 0,
  int tokensOut = 0,
  int requests = 0,
  int windowSeconds = 86400,
  List<AnsweredModel> byModel = const [],
}) => OverviewNode(
  name: 'spark-1',
  online: true,
  answered: NodeAnswered(
    windowSeconds: windowSeconds,
    tokensIn: tokensIn,
    tokensCached: tokensCached,
    tokensOut: tokensOut,
    requests: requests,
    byModel: byModel,
  ),
);
