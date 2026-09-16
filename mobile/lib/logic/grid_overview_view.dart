/// A grid's live state, as the computer projected it for this phone.
///
/// The phone holds no grid credential and cannot call the relay itself, so
/// everything here arrived already decided: the numbers are formatted, the
/// labels are written, the machines are sorted strongest first. What is left is
/// a fraction per bar slice, because geometry is the one thing the drawing side
/// has to do for itself.
///
/// Every field is read defensively. A desktop older than this screen sends no
/// `overview` at all, and one newer may send a key this build has never heard
/// of — both have to read as "show what you understand", never as a parse that
/// throws on a phone the user cannot get a fix onto quickly.
library;

/// What the grid can do — one chip. [icon] is a name, not a glyph: the phone
/// picks the glyph, so the two apps don't have to agree on an icon font.
typedef GridCapability = ({String icon, String label});

/// One model the grid serves, ready to copy.
typedef GridModelRow = ({String id, String kind, String icon});

/// One machine's share of the grid's graphics memory.
typedef GridMemoryShare = ({String label, String value, double fraction});

/// A "label … value unit" figure under the memory block.
typedef GridStatRow = ({String label, String value, String unit});

/// One machine on the grid.
typedef GridNodeRow = ({
  String name,
  List<String> specs,
  bool online,
  String plan,
  bool media,
});

/// The grid's pooled hardware. [memory] and [split] are empty together when no
/// machine advertises graphics memory but something still reports capacity or
/// speed.
typedef GridPowerBlock = ({
  String memory,
  List<GridMemoryShare> split,
  List<GridStatRow> stats,
});

/// Everything live about a grid.
typedef GridOverviewView = ({
  List<String> meta,
  List<GridCapability> can,
  List<GridModelRow> models,
  GridPowerBlock? power,
  List<GridNodeRow> nodes,
});

/// The overview in [value], or null when the computer sent none — an older
/// desktop, or a relay that would not answer. Null means "no live state to
/// show", which is a different screen from a grid that is empty.
GridOverviewView? gridOverviewFrom(Object? value) {
  if (value is! Map) return null;
  return (
    meta: _strings(value['meta']),
    can: [
      for (final chip in _maps(value['can']))
        (icon: _text(chip['icon']), label: _text(chip['label'])),
    ],
    models: [
      for (final model in _maps(value['models']))
        if (_text(model['id']).isNotEmpty)
          (
            id: _text(model['id']),
            kind: _text(model['kind']),
            icon: _text(model['icon']),
          ),
    ],
    power: _power(value['power']),
    nodes: [
      for (final node in _maps(value['nodes']))
        (
          name: _text(node['name']),
          specs: _strings(node['specs']),
          online: node['online'] == true,
          plan: _text(node['plan']),
          media: node['media'] == true,
        ),
    ],
  );
}

GridPowerBlock? _power(Object? value) {
  if (value is! Map) return null;
  final stats = [
    for (final stat in _maps(value['stats']))
      (
        label: _text(stat['label']),
        value: _text(stat['value']),
        unit: _text(stat['unit']),
      ),
  ];
  final split = [
    for (final share in _maps(value['split']))
      (
        label: _text(share['label']),
        value: _text(share['value']),
        fraction: _fraction(share['fraction']),
      ),
  ];
  // A card with neither half is not an empty card, it is no card: the caller
  // draws nothing rather than a heading over blank space.
  if (stats.isEmpty && split.isEmpty) return null;
  return (memory: _text(value['memory']), split: split, stats: stats);
}

List<Map<Object?, Object?>> _maps(Object? value) => [
  for (final item in value is List ? value : const [])
    if (item is Map) item,
];

List<String> _strings(Object? value) => [
  for (final item in value is List ? value : const [])
    if (item is String && item.isNotEmpty) item,
];

String _text(Object? value) => value is String ? value : '';

/// A share of the bar, clamped to 0–1: a slice wider than the bar it sits in
/// would push every slice after it off the end.
double _fraction(Object? value) {
  final raw = value is num ? value.toDouble() : 0.0;
  if (raw.isNaN || raw <= 0) return 0;
  return raw > 1 ? 1 : raw;
}
