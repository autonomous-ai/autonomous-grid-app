import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/node_dashboard_view.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

/// A node with only the fields a given test cares about — everything else stays
/// null, which is what a real relay sends for a machine that reports little.
OverviewNode _node(
  String name, {
  int? tokensOut,
  int? requests,
  double? throughputTokS,
  double? vramGb,
  String? platform,
  List<String> models = const [],
  String? model,
}) => OverviewNode(
  name: name,
  online: true,
  throughputTokS: throughputTokS,
  vramGb: vramGb,
  platform: platform,
  models: models,
  model: model,
  answered: tokensOut == null && requests == null
      ? null
      : NodeAnswered(
          windowSeconds: 86400,
          tokensOut: tokensOut ?? 0,
          requests: requests ?? 0,
        ),
);

List<String> _names(List<OverviewNode> nodes) => [
  for (final n in nodes) n.name,
];

void main() {
  group('sortNodes', () {
    test('ranks the busiest machine first, so it opens on who is working', () {
      final sorted = sortNodes([
        _node('quiet', tokensOut: 98),
        _node('busy', tokensOut: 27000),
        _node('middling', tokensOut: 1900),
      ], NodeSortKey.outputTokens);

      expect(_names(sorted), ['busy', 'middling', 'quiet']);
    });

    test('a node nobody measured sorts below one measured at zero', () {
      // The distinction the whole dashboard protects: `answered == null` is an
      // older relay saying nothing, and must not be filed among the machines
      // that were counted and found idle.
      final sorted = sortNodes([
        _node('never-measured'),
        _node('measured-idle', tokensOut: 0),
      ], NodeSortKey.outputTokens);

      expect(_names(sorted), ['measured-idle', 'never-measured']);
    });

    test('requests and output tokens disagree, and each is honoured', () {
      // One long answer against many short ones — the two orders must not
      // collapse into each other, or the second sort button does nothing.
      final nodes = [
        _node('long-answers', tokensOut: 900000, requests: 3),
        _node('many-turns', tokensOut: 12000, requests: 4200),
      ];

      expect(_names(sortNodes(nodes, NodeSortKey.outputTokens)), [
        'long-answers',
        'many-turns',
      ]);
      expect(_names(sortNodes(nodes, NodeSortKey.requests)), [
        'many-turns',
        'long-answers',
      ]);
    });

    test('a zero decode rate ranks as unmeasured, matching what the card '
        'prints', () {
      // `throughputLabel` renders 0 as "—", because the relay only advertises a
      // rate once it has timed a request. A card reading "—" must not outrank
      // one reading a real number.
      final sorted = sortNodes([
        _node('never-timed', throughputTokS: 0),
        _node('slow', throughputTokS: 1),
      ], NodeSortKey.throughput);

      expect(_names(sorted), ['slow', 'never-timed']);
    });

    test('sorts by memory, biggest pool first', () {
      final sorted = sortNodes([
        _node('small', vramGb: 63.7),
        _node('big', vramGb: 192),
      ], NodeSortKey.memory);

      expect(_names(sorted), ['big', 'small']);
    });

    test('sorts by name without regard to case', () {
      final sorted = sortNodes([
        _node('zeta'),
        _node('Alpha'),
        _node('beta'),
      ], NodeSortKey.name);

      expect(_names(sorted), ['Alpha', 'beta', 'zeta']);
    });

    test('breaks ties by name, so a poll cannot shuffle equal machines', () {
      final sorted = sortNodes([
        _node('charlie', tokensOut: 500),
        _node('alpha', tokensOut: 500),
        _node('bravo', tokensOut: 500),
      ], NodeSortKey.outputTokens);

      expect(_names(sorted), ['alpha', 'bravo', 'charlie']);
    });

    test('leaves the list it was given alone', () {
      final original = [_node('b', tokensOut: 1), _node('a', tokensOut: 9)];

      sortNodes(original, NodeSortKey.outputTokens);

      expect(_names(original), ['b', 'a']);
    });
  });

  group('applyNodeDashboardView', () {
    final mac = _node(
      'mac',
      platform: 'macos-arm64',
      models: ['gemma-4-31b-it'],
      tokensOut: 10,
    );
    final linux = _node(
      'linux-box',
      platform: 'linux',
      models: ['gemma-4-31b-it', 'qwen/Qwen3.8-27B'],
      tokensOut: 90,
    );
    final windows = _node(
      'win-box',
      platform: 'windows',
      models: ['laguna-s-2.1'],
      tokensOut: 50,
    );
    final nodes = [mac, linux, windows];

    test('shows everything, busiest first, with no filter set', () {
      final shown = applyNodeDashboardView(nodes, const NodeDashboardView());

      expect(_names(shown), ['linux-box', 'win-box', 'mac']);
    });

    test('keeps only the machines serving the chosen model', () {
      final view = const NodeDashboardView().showingModel('gemma-4-31b-it');

      expect(_names(applyNodeDashboardView(nodes, view)), ['linux-box', 'mac']);
    });

    test('matches a model whatever case the node advertised it in', () {
      // The catalog, the node and the relay disagree on case; a filter that
      // missed because of it would look like a model nobody serves.
      final view = const NodeDashboardView().showingModel('QWEN/qwen3.8-27b');

      expect(_names(applyNodeDashboardView(nodes, view)), ['linux-box']);
    });

    test('keeps only the machines on the chosen platform', () {
      final view = const NodeDashboardView().showingPlatform('macOS');

      expect(_names(applyNodeDashboardView(nodes, view)), ['mac']);
    });

    test('a node that reported no platform is excluded by a platform '
        'filter', () {
      // Passing it through would put a machine under a heading it may not
      // belong to, with nothing on the card saying it was a guess.
      final view = const NodeDashboardView().showingPlatform('Linux');

      expect(
        _names(applyNodeDashboardView([...nodes, _node('silent')], view)),
        ['linux-box'],
      );
    });

    test('applies both filters at once', () {
      final view = const NodeDashboardView()
          .showingModel('gemma-4-31b-it')
          .showingPlatform('Linux');

      expect(_names(applyNodeDashboardView(nodes, view)), ['linux-box']);
    });

    test('sorts what survives the filter, not what went in', () {
      final view = const NodeDashboardView(
        sort: NodeSortKey.name,
      ).showingModel('gemma-4-31b-it');

      expect(_names(applyNodeDashboardView(nodes, view)), ['linux-box', 'mac']);
    });

    test('clearing brings every machine back and keeps the order', () {
      final view = const NodeDashboardView(
        sort: NodeSortKey.name,
      ).showingModel('gemma-4-31b-it').unfiltered;

      expect(view.isFiltered, isFalse);
      expect(view.sort, NodeSortKey.name);
      expect(_names(applyNodeDashboardView(nodes, view)), [
        'linux-box',
        'mac',
        'win-box',
      ]);
    });

    test('changing the sort leaves the filters in place', () {
      final view = const NodeDashboardView()
          .showingPlatform('Linux')
          .sortedBy(NodeSortKey.name);

      expect(view.platform, 'Linux');
      expect(view.sort, NodeSortKey.name);
    });
  });

  group('nodeDashboardModels', () {
    test('lists each model once, in the spelling its node advertised', () {
      final models = nodeDashboardModels([
        _node('a', models: ['Gemma-4-31B-it']),
        _node('b', models: ['gemma-4-31b-it', 'laguna-s-2.1']),
      ]);

      expect(models, ['Gemma-4-31B-it', 'laguna-s-2.1']);
    });

    test('drops the relay auto router, which no machine actually serves', () {
      final models = nodeDashboardModels([
        _node('a', models: ['auto', 'laguna-s-2.1']),
      ]);

      expect(models, ['laguna-s-2.1']);
    });

    test('falls back to the primary model when a node advertises no list', () {
      expect(nodeDashboardModels([_node('a', model: 'solo-1')]), ['solo-1']);
    });
  });

  group('nodeDashboardPlatforms', () {
    test('offers only the systems the grid actually runs', () {
      final platforms = nodeDashboardPlatforms([
        _node('a', platform: 'windows'),
        _node('b', platform: 'macos-arm64'),
        _node('c', platform: 'macos-x86_64'),
        _node('d'),
      ]);

      expect(platforms, ['macOS', 'Windows']);
    });
  });

  group('modelLabelForKey', () {
    test('names the model in the spelling the grid advertises', () {
      expect(
        modelLabelForKey(['Gemma-4-31B-it'], 'gemma-4-31b-it'),
        'Gemma-4-31B-it',
      );
    });

    test('still names a model whose machine has gone offline', () {
      // The button has to keep saying what is being asked for, or an empty
      // dashboard has no visible cause.
      expect(modelLabelForKey(const [], 'laguna-s-2.1'), 'laguna-s-2.1');
    });
  });

  group('nodeDashboardSubtitle', () {
    test('counts the machines when nothing is hidden', () {
      expect(
        nodeDashboardSubtitle(9, 9),
        '9 machines serving · readings refresh with the grid overview',
      );
    });

    test('shows the ratio only while a filter is hiding machines', () {
      expect(nodeDashboardSubtitle(9, 3), startsWith('3 of 9 machines'));
    });

    test('says a lone machine in the singular', () {
      expect(nodeDashboardSubtitle(1, 1), startsWith('1 machine serving'));
    });

    test('agrees with the total, not the count shown', () {
      expect(nodeDashboardSubtitle(9, 1), startsWith('1 of 9 machines'));
    });

    test('an empty grid says so plainly rather than counting to zero', () {
      expect(
        nodeDashboardSubtitle(0, 0),
        'No machines are serving this grid right now.',
      );
    });
  });
}
