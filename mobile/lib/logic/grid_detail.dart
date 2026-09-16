/// One grid, as the phone is shown it.
///
/// What the list carries plus the part worth opening a screen for: whether this
/// is the grid the computer is actually working in, what it is serving to it
/// right now, and the grid's own live state — models, machines, pooled hardware
/// — which the computer fetched from the relay on this phone's behalf.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'grid_overview_view.dart';
import 'phone_link_controller.dart';

/// One engine this computer serves to a grid.
///
/// [running] is the honest half. `grid join` detaches, so a record outliving its
/// process is the ordinary way an engine stops — a list that hid those would
/// show "nothing here" for a grid the computer believes it is still serving.
typedef GridEngineRow = ({String id, List<String> models, bool running});

/// A grid, opened.
typedef GridDetail = ({
  String id,
  String name,
  String type,
  String email,
  bool current,
  List<GridEngineRow> engines,
  GridOverviewView? overview,
});

/// What the computer says about one grid.
///
/// `retry: null` for the usual reason: a failure here is almost always the
/// channel being down, and ten retries are ten more requests into a socket that
/// is not answering.
final gridDetailProvider = FutureProvider.family<GridDetail, String>((
  ref,
  gridId,
) async {
  final result = await ref.watch(phoneLinkProvider.notifier).call('grids.get', {
    'id': gridId,
  });
  final engines = result['engines'];
  return (
    id: '${result['id'] ?? gridId}',
    name: '${result['name'] ?? ''}',
    type: '${result['type'] ?? ''}',
    email: '${result['email'] ?? ''}',
    current: result['current'] == true,
    engines: [
      for (final engine in engines is List ? engines : const [])
        if (engine is Map)
          (
            id: '${engine['id'] ?? ''}',
            models: [
              for (final model
                  in engine['models'] is List
                      ? engine['models']! as List
                      : const [])
                if (model is String) model,
            ],
            running: engine['running'] == true,
          ),
    ],
    // Null on a computer too old to send one, and on a grid whose relay would
    // not answer. Both mean the same thing here: show the half that came off
    // the computer's own disk, and no live figures.
    overview: gridOverviewFrom(result['overview']),
  );
}, retry: null);
