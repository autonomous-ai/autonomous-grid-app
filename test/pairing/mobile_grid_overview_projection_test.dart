import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/phone/logic/phone_grid_overview.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

/// A grid with two machines of very different size, one asleep, and a model
/// advertised twice by providers that disagree on case — the three things a
/// real grid does that a hand-written fixture never does.
GridOverview _overview({
  bool bigNodeOnline = true,
  double? throughput = 480,
  double? vram = 382.4,
}) => GridOverview.fromJson({
  'grid': {'state': 'active'},
  'stats': {
    'models': 0,
    'nodes': 2,
    'uptime_pct': 99.9,
    'concurrent_capacity': 57,
  },
  'models': [
    {'id': 'Qwen/Qwen3.8-27B', 'modality': 'text', 'context_length': 32768},
    {'id': 'qwen/qwen3.8-27b', 'modality': 'text'},
    {'id': 'auto'},
  ],
  'nodes': [
    {
      'name': 'scholes-60001',
      'online': bigNodeOnline,
      'vram_gb': vram,
      'models': ['Qwen/Qwen3.8-27B'],
      'engine': 'llama.cpp',
      'device_class': 'gpu',
      'max_concurrency': 40,
      'throughput_tok_s': throughput,
    },
    {
      'name': 'scholes-60002',
      'online': true,
      // Follows [vram]: "this grid advertises no memory" has to mean every
      // machine on it, or the pool still has something to total.
      'vram_gb': vram == null ? null : 64,
      'models': ['Qwen/Qwen3.8-27B'],
      'engine': 'llama.cpp',
    },
  ],
});

Map<String, Object?> _power(Map<String, Object?> projection) =>
    projection['power']! as Map<String, Object?>;

List<Object?> _list(Map<String, Object?> from, String key) =>
    from[key]! as List<Object?>;

/// The phone holds no grid credential, so every figure on its grid screen is
/// one this computer measured and wrote down for it. These pin *what* crosses
/// that wire: finished words where a formatting rule decided them, fractions
/// where the phone still has to draw something, and nothing at all where the
/// grid has nothing to say.
void main() {
  group('the grid a phone is shown', () {
    test('counts the models it resolved, not the zero the relay sent', () {
      // A relay that does not detail its models reports `stats.models: 0` while
      // still listing them. The phone prints this line as-is, so a 0 here is a
      // grid that reads as empty on one screen and full on the next.
      final meta = _list(phoneOverviewProjection(_overview()), 'meta');
      expect(meta.first, '1 model');
      expect(meta, contains('99.9% uptime'));
    });

    test('the same model advertised twice is one row', () {
      // `Qwen/Qwen3.8-27B` and `qwen/qwen3.8-27b` are one model two providers
      // spell differently, and the virtual `auto` router is not a model at all.
      final models = _list(phoneOverviewProjection(_overview()), 'models');
      expect(models, hasLength(1));
      expect((models.single! as Map)['id'], 'Qwen/Qwen3.8-27B');
    });

    test('a grid that serves text says it can chat', () {
      final can = _list(phoneOverviewProjection(_overview()), 'can');
      expect(can.single, {'icon': 'chat', 'label': 'Chat'});
    });

    test('memory is written once, by the side that measured it', () {
      // The phone prints this string. It never divides by 1024 or decides where
      // a decimal goes, which is why those rules can change in one place.
      final power = _power(phoneOverviewProjection(_overview()));
      expect(power['memory'], '446.4 GB');
      expect(_list(power, 'stats'), [
        {'label': 'Runs at once', 'value': '57', 'unit': 'tasks'},
        {'label': 'Speed', 'value': '~480', 'unit': 'tok/s'},
      ]);
    });

    test('each machine gets its share of the bar, biggest first', () {
      // The fraction is the one number the phone is left to act on: it draws
      // the bar. The order is the colour order, so it has to be decided here.
      final split = _list(
        _power(phoneOverviewProjection(_overview())),
        'split',
      );
      expect(split, hasLength(2));
      final first = split.first! as Map;
      expect(first['label'], '60001');
      expect(first['value'], '382.4 GB');
      expect(first['fraction'], closeTo(0.857, 0.001));
      expect((split.last! as Map)['label'], '60002');
    });

    test('a machine that is asleep brings no memory to the pool', () {
      // It stays in the list — a machine that vanished would read as one that
      // left the grid — but the pool is what the grid can do right now.
      final projection = phoneOverviewProjection(
        _overview(bigNodeOnline: false),
      );
      expect(_power(projection)['memory'], '64 GB');
      expect(_list(_power(projection), 'split'), hasLength(1));
      expect(_list(projection, 'nodes'), hasLength(2));
    });

    test('a machine carries the same facts its row does on the computer', () {
      final nodes = _list(phoneOverviewProjection(_overview()), 'nodes');
      final biggest = nodes.first! as Map;
      expect(biggest['name'], 'scholes-60001');
      expect(biggest['online'], isTrue);
      expect(biggest['specs'], [
        'llama.cpp',
        'GPU',
        '382.4 GB VRAM',
        '1 chat model',
        '40 parallel',
        '~480 tok/s',
      ]);
      // No plan: an ordinary machine is not a subscription seat, and an empty
      // badge would be a tier nobody is on.
      expect(biggest.containsKey('plan'), isFalse);
    });

    test('a grid that only says how much it runs at once shows just that', () {
      // Half a story is still a story. The memory block goes; the row with a
      // figure behind it stays.
      final power = _power(
        phoneOverviewProjection(_overview(vram: null, throughput: null)),
      );
      expect(power.containsKey('memory'), isFalse);
      expect(_list(power, 'stats'), [
        {'label': 'Runs at once', 'value': '57', 'unit': 'tasks'},
      ]);
    });

    test('a grid advertising no hardware at all gets no power card', () {
      // Null, not an empty card: "Grid power" over three dashes tells a person
      // less than the section not being there at all.
      final bare = GridOverview.fromJson({
        'stats': {'models': 1, 'nodes': 1},
        'models': [
          {'id': 'llama'},
        ],
        'nodes': [
          {
            'name': 'laptop',
            'online': true,
            'models': ['llama'],
          },
        ],
      });
      expect(phoneOverviewProjection(bare)['power'], isNull);
      // And the rest of the screen still arrives.
      expect(_list(phoneOverviewProjection(bare), 'nodes'), hasLength(1));
    });
  });
}
