import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_power_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

OverviewNode _node({
  String name = 'n',
  bool online = true,
  double? vramGb,
  double? vramTotalMb,
  int? concurrency,
  double? throughput,
}) => OverviewNode.fromJson({
  'name': name,
  'online': online,
  'vram_gb': ?vramGb,
  'vram_total_mb': ?vramTotalMb,
  'max_concurrency': ?concurrency,
  'throughput_tok_s': ?throughput,
});

void main() {
  group('gridPowerFrom', () {
    test('sums hardware across online nodes only', () {
      final power = gridPowerFrom([
        _node(vramGb: 64, concurrency: 3, throughput: 40),
        _node(vramGb: 382.4, concurrency: 16, throughput: 140),
      ], 7);

      expect(power.onlineNodes, 2);
      expect(power.models, 7);
      expect(power.vramGb, closeTo(446.4, 0.001));
      expect(power.parallel, 19);
      expect(power.throughputTokS, closeTo(180, 0.001));
    });

    test('excludes offline nodes from every total', () {
      final power = gridPowerFrom([
        _node(vramGb: 64, concurrency: 3, throughput: 40),
        _node(online: false, vramGb: 999, concurrency: 99, throughput: 999),
      ], 4);

      expect(power.onlineNodes, 1);
      expect(power.vramGb, 64);
      expect(power.parallel, 3);
      expect(power.throughputTokS, 40);
    });

    test('leaves a total null when no online node reports it', () {
      // A CPU-only grid must not claim "0 GB" — absent and zero are different
      // claims, and the pill hides the row entirely on null.
      final power = gridPowerFrom([_node(concurrency: 2)], 1);

      expect(power.vramGb, isNull);
      expect(power.throughputTokS, isNull);
      expect(power.parallel, 2);
      expect(power.hasSpecs, isTrue);
    });

    test('hasSpecs is false when a grid reports no hardware at all', () {
      final power = gridPowerFrom([_node()], 1);

      expect(power.hasSpecs, isFalse);
      expect(power.isEmpty, isFalse); // still has a node and a model to show
    });

    test('falls back to vram_total_mb when vram_gb is absent', () {
      final power = gridPowerFrom([_node(vramTotalMb: 24576)], 1);

      expect(power.vramGb, closeTo(24, 0.001));
    });

    test('prefers vram_gb over the raw megabyte fallback', () {
      final power = gridPowerFrom([_node(vramGb: 48, vramTotalMb: 999999)], 1);

      expect(power.vramGb, 48);
    });

    test('ignores non-positive hardware figures', () {
      final power = gridPowerFrom([
        _node(vramGb: 0, concurrency: 0, throughput: 0),
      ], 1);

      expect(power.vramGb, isNull);
      expect(power.parallel, isNull);
      expect(power.throughputTokS, isNull);
    });

    test('prefers the relay capacity over summing node concurrency', () {
      // The relay is the authority on how much work it will dispatch; it may
      // cap or oversubscribe what the nodes individually advertise.
      final power = gridPowerFrom(
        [_node(concurrency: 8), _node(concurrency: 12)],
        8,
        capacity: 15,
      );

      expect(power.parallel, 15);
    });

    test('falls back to summing when the relay reports no capacity', () {
      final power = gridPowerFrom([
        _node(concurrency: 8),
        _node(concurrency: 12),
      ], 8);

      expect(power.parallel, 20);
    });

    test('ignores a zero capacity and sums instead', () {
      // A relay that hasn't computed capacity yet sends 0, which would read as
      // "this grid can serve nothing" — the nodes know better.
      final power = gridPowerFrom([_node(concurrency: 3)], 1, capacity: 0);

      expect(power.parallel, 3);
    });

    test('the Art grid: capacity without any VRAM reported', () {
      // Real payload: two online nodes, neither advertising GPU memory. The
      // panel falls back to a plain machine list, so vramGb must stay null
      // rather than becoming 0 and drawing an empty bar.
      final power = gridPowerFrom(
        [
          _node(name: 'Ngoc-Dos-MacBook-Pro.local', concurrency: 8),
          _node(name: '75543b6a3c33', concurrency: 12),
        ],
        8,
        capacity: 20,
      );

      expect(power.vramGb, isNull);
      expect(power.parallel, 20);
      expect(power.onlineNodes, 2);
      expect(power.hasSpecs, isTrue); // capacity alone is worth a footer row
    });

    test('isEmpty only when nothing is online and nothing is served', () {
      expect(gridPowerFrom(const [], 0).isEmpty, isTrue);
      expect(gridPowerFrom(const [], 3).isEmpty, isFalse);
      expect(gridPowerFrom([_node(online: false)], 0).isEmpty, isTrue);
      expect(gridPowerFrom([_node()], 0).isEmpty, isFalse);
    });
  });

  group('formatVram', () {
    test('drops a trailing zero, keeps one decimal otherwise', () {
      expect(formatVram(64), '64 GB');
      expect(formatVram(446.4), '446.4 GB');
      expect(formatVram(47.5), '47.5 GB');
    });

    test('switches to TB past 1024 GB so the figure stays scannable', () {
      expect(formatVram(1024), '1 TB');
      expect(formatVram(1228.8), '1.2 TB');
      expect(formatVram(1023), '1023 GB');
    });
  });

  group('formatThroughput', () {
    test('rounds — the underlying figure is an estimate', () {
      expect(formatThroughput(180.4), '~180');
      expect(formatThroughput(179.6), '~180');
    });
  });

  group('nodeVramGb', () {
    test('returns null rather than zero for a node with no GPU', () {
      expect(nodeVramGb(_node()), isNull);
      expect(nodeVramGb(_node(vramGb: 0)), isNull);
      expect(nodeVramGb(_node(vramGb: 64)), 64);
    });
  });

  group('plural', () {
    test('drops the s for exactly one', () {
      expect(plural(1, 'node'), 'node');
      expect(plural(1, 'model'), 'model');
      expect(plural(1, 'request'), 'request');
      expect(plural(1, 'Machine'), 'Machine');
    });

    test('adds the s for zero and for many', () {
      expect(plural(0, 'node'), 'nodes');
      expect(plural(2, 'node'), 'nodes');
      expect(plural(12, 'model'), 'models');
    });

    test('takes an explicit plural for irregular words', () {
      expect(plural(2, 'entry', 'entries'), 'entries');
      expect(plural(1, 'entry', 'entries'), 'entry');
    });
  });

  group('sortNodesByPower', () {
    test('puts the biggest machine first', () {
      final sorted = sortNodesByPower([
        _node(name: 'small', vramGb: 32),
        _node(name: 'big', vramGb: 382.4),
        _node(name: 'mid', vramGb: 64),
      ]);

      expect([for (final n in sorted) n.name], ['big', 'mid', 'small']);
    });

    test('sinks VRAM-less nodes below every GPU node', () {
      final sorted = sortNodesByPower([
        _node(name: 'cpu-only'),
        _node(name: 'gpu', vramGb: 8),
      ]);

      expect([for (final n in sorted) n.name], ['gpu', 'cpu-only']);
    });

    test('breaks ties by name so the order does not shuffle on refresh', () {
      final sorted = sortNodesByPower([
        _node(name: 'zeta', vramGb: 64),
        _node(name: 'alpha', vramGb: 64),
      ]);

      expect([for (final n in sorted) n.name], ['alpha', 'zeta']);
    });

    test('leaves the caller list untouched', () {
      final original = [
        _node(name: 'small', vramGb: 32),
        _node(name: 'big', vramGb: 382.4),
      ];
      sortNodesByPower(original);

      expect(original.first.name, 'small');
    });
  });

  group('shortenNodeNames', () {
    test('drops a shared prefix so the differing part reads first', () {
      expect(
        shortenNodeNames([
          'MacBooks-MacBook-Pro-6.local',
          'MacBooks-MacBook-Pro-6',
        ]),
        ['MacBook-Pro-6.local', 'MacBook-Pro-6'],
      );
    });

    test('only cuts at a separator, never mid-word', () {
      // Common prefix is "node-1" but cutting there would leave "0" and "1";
      // the safe cut is after "node-".
      expect(shortenNodeNames(['node-10', 'node-11']), ['10', '11']);
    });

    test('leaves names alone when they share no separator-aligned prefix', () {
      expect(shortenNodeNames(['alpha', 'beta']), ['alpha', 'beta']);
    });

    test('trims a repeated prefix even when one machine does not share it', () {
      // The shipped grid: two MacBooks beside a rented box. An earlier version
      // required *every* name to share the prefix, so the odd machine out
      // disabled the trim and both MacBooks stayed truncated in the UI.
      expect(
        shortenNodeNames([
          'engine-b0dc5f98',
          'MacBooks-MacBook-Pro-6',
          'MacBooks-MacBook-Pro-6.local',
        ]),
        ['engine-b0dc5f98', 'MacBook-Pro-6', 'MacBook-Pro-6.local'],
      );
    });

    test('trims each group independently', () {
      expect(shortenNodeNames(['rig-a', 'rig-b', 'lab-x', 'lab-y']), [
        'a',
        'b',
        'x',
        'y',
      ]);
    });

    test('leaves a machine standing alone at full name', () {
      expect(shortenNodeNames(['solo-box', 'pair-a', 'pair-b']), [
        'solo-box',
        'a',
        'b',
      ]);
    });

    test('leaves a single name alone — nothing to disambiguate against', () {
      expect(shortenNodeNames(['MacBooks-MacBook-Pro-6']), [
        'MacBooks-MacBook-Pro-6',
      ]);
    });

    test('refuses a trim that would empty a name', () {
      // "rig-" is a separator-aligned prefix, but trimming leaves "" for the
      // first entry, so the original names stand.
      expect(shortenNodeNames(['rig-', 'rig-2']), ['rig-', 'rig-2']);
    });

    test('handles identical names without producing empties', () {
      expect(shortenNodeNames(['same', 'same']), ['same', 'same']);
    });

    test('is a no-op on an empty list', () {
      expect(shortenNodeNames(const []), isEmpty);
    });
  });
}
