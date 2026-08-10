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
  group('a reading the node never sent is absent, never zero', () {
    test('a node reporting only total VRAM states it, with no bar', () {
      // An Intel Mac: macOS gives the card's size but never its occupancy. The
      // total is a real fact worth showing — it is the pool a model must fit
      // into — while "0 / 4 GB" would state a measurement nobody made.
      final metric = vramMetric(_node(vramTotalMb: 4096))!;

      expect(metric.value, '4 GB');
      expect(metric.fraction, isNull);
      expect(freeVramLabel(_node(vramTotalMb: 4096)), isNull);
    });

    test(
      'a node reporting no temperature, power or disk shows none of them',
      () {
        final node = _node(vramTotalMb: 131072, vramUsedMb: 1024);

        expect(temperatureMetric(node), isNull);
        expect(powerMetric(node), isNull);
        expect(storageMetric(node), isNull);
      },
    );

    test('a genuine zero is still shown, because idle is a real reading', () {
      // The distinction the whole file turns on: absent means "not measured",
      // 0% means "measured, and this node is doing nothing right now".
      expect(usageMetric(_node(gpuUtilPct: 0))?.value, '0%');
      expect(usageMetric(_node()), isNull);
    });

    test('a node that has served nothing reports no throughput', () {
      expect(throughputLabel(_node()), isNull);
      expect(throughputLabel(_node(throughputTokS: 0)), isNull);
      expect(throughputLabel(_node(throughputTokS: 248.7)), '249');
    });
  });

  group('figures read the way an operator expects them', () {
    test('memory pairs used against total', () {
      final metric = vramMetric(
        _node(vramTotalMb: 124620, vramUsedMb: 100556),
      )!;

      expect(metric.value, '98.2 / 121.7 GB');
      expect(metric.fraction, closeTo(0.807, 0.001));
    });

    test('a whole number drops its decimal, a fractional one keeps it', () {
      // A 3755 GB drive should not read "3755.0 GB" beside a "541.4".
      expect(formatMetricNumber(3755), '3755');
      expect(formatMetricNumber(541.44), '541.4');
    });

    test('power shows the draw against the card cap', () {
      final metric = powerMetric(_node(gpuPowerW: 42.39, gpuPowerLimitW: 120))!;

      expect(metric.value, '42.4W / 120W');
      expect(metric.fraction, closeTo(0.353, 0.001));
    });

    test('a card reporting draw but no cap still gets a row, with no bar', () {
      final metric = powerMetric(_node(gpuPowerW: 42.39))!;

      expect(metric.value, '42.4W');
      expect(metric.fraction, isNull);
    });

    test('storage pairs used against the volume total', () {
      final metric = storageMetric(
        _node(diskTotalGb: 3755, diskUsedGb: 541.4),
      )!;

      expect(metric.value, '541.4 / 3755 GB');
    });

    test('free memory is only derived when both sides were measured', () {
      expect(
        freeVramLabel(_node(vramTotalMb: 124620, vramUsedMb: 111206)),
        '13.1 GB',
      );
      expect(freeVramLabel(_node(vramTotalMb: 124620)), isNull);
    });
  });

  group('bars never overflow their track', () {
    test('a provider reporting past its own ceiling pins at full', () {
      // A bad reading should make the card look pinned, not break its layout.
      expect(usageMetric(_node(gpuUtilPct: 140))!.fraction, 1.0);
      expect(
        vramMetric(_node(vramTotalMb: 1024, vramUsedMb: 4096))!.fraction,
        1.0,
      );
    });

    test(
      'tone rises with the reading so a busy node is spottable at a glance',
      () {
        expect(usageMetric(_node(gpuUtilPct: 12))!.tone, MetricTone.calm);
        expect(usageMetric(_node(gpuUtilPct: 70))!.tone, MetricTone.warm);
        expect(usageMetric(_node(gpuUtilPct: 95))!.tone, MetricTone.hot);
      },
    );
  });

  group('a node with no gauges explains itself instead of showing a blank', () {
    test('a node with a size but no occupancy still explains itself', () {
      // The row exists (a bar-less "4 GB"), so this is keyed on there being no
      // *fraction* to fill — not on the reading list being empty.
      final node = _node(vramTotalMb: 4096, platform: 'macos-x86_64');

      expect(nodeBars(node), hasLength(1));
      expect(missingTelemetryReason(node), isNotNull);
    });

    test('a Mac is given no platform excuse, because there is none to give', () {
      // A message here once blamed system permissions for a Mac's missing
      // gauges. It was false — the IORegistry publishes them to any user — so a
      // Mac reaching this point is a probe that failed, like any other node.
      final mac = _node(vramTotalMb: 4096, platform: 'macos-x86_64');
      final linux = _node(vramTotalMb: 4096, platform: 'linux');

      expect(missingTelemetryReason(mac), missingTelemetryReason(linux));
      expect(missingTelemetryReason(mac), isNot(contains('macOS')));
    });

    test('a Mac reporting real readings is not explained away at all', () {
      final node = _node(
        vramTotalMb: 4096,
        vramUsedMb: 824,
        gpuUtilPct: 8,
        gpuTempC: 66,
        platform: 'macos-x86_64',
      );

      expect(missingTelemetryReason(node), isNull);
    });

    test('a processor-only node says so', () {
      expect(
        missingTelemetryReason(_node(platform: 'linux')),
        contains('processor'),
      );
    });

    test('a node that does report gauges has nothing to explain', () {
      final node = _node(vramTotalMb: 124620, vramUsedMb: 100556);

      expect(nodeBars(node), isNotEmpty);
      expect(missingTelemetryReason(node), isNull);
    });
  });
}
