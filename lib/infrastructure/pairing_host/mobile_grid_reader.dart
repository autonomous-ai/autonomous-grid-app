/// What a paired phone is told about one grid.
///
/// The same projection rule as everywhere else in this folder: built by reading
/// only the fields it may send. `credentials.toml` holds `access_token` and
/// `refresh_token` for every grid — bearer credentials for the whole thing —
/// and nothing here ever holds one, so nothing here can leak one.
///
/// Two fields are deliberately left out of the engine records as well:
///
///  - **`pid`**. It is read, because it is how liveness is decided, and then
///    thrown away. A process id tells a phone nothing it can use and names a
///    process on somebody's computer. The probe is [pidIsAlive], which shells
///    out to `kill -0` on purpose: `Process.killPid` always sends a real
///    signal, so the obvious shortcut would stop the engine it was asking
///    about.
///  - **`endpoint_url`**. Where an engine actually listens is this machine's
///    network layout. The phone is shown *what* is being served, not where.
///
/// Flutter-free, like the rest of this folder.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../core/process_liveness.dart';

/// One engine this computer is serving to a grid.
typedef GridEngine = ({String id, List<String> models, bool running});

/// The engines this computer is serving to [gridId], live ones and stale
/// records alike.
///
/// A stale record is kept rather than hidden: `grid join` detaches, so a record
/// outliving its process is the ordinary way an engine stops, and a phone that
/// silently dropped them would show "nothing here" for a grid the computer
/// believes it is still serving. [GridEngine.running] is the honest difference.
List<GridEngine> readGridEngines(String gridId, {Directory? runDir}) {
  // The id indexes a directory name, so it is the one field a caller picks.
  if (!_isGridId(gridId)) return const [];
  final dir = runDir ?? GridPaths.engineRunDir(gridId);
  if (!dir.existsSync()) return const [];
  final out = <GridEngine>[];
  for (final entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final record = _engineOf(entity);
    if (record != null) out.add(record);
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}

/// The engine [file] describes, or null when it is not a usable record.
GridEngine? _engineOf(File file) {
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on Object {
    return null;
  }
  if (decoded is! Map) return null;
  final id = decoded['engine_id'];
  if (id is! String || id.isEmpty) return null;
  return (
    id: id,
    models: _models(decoded),
    running: pidIsAlive(decoded['pid'] is int ? decoded['pid'] as int : null),
  );
}

/// Every model the record advertises, from `engines[]` where it has one and
/// from the flat field where it predates that.
List<String> _models(Map<Object?, Object?> record) {
  final out = <String>{};
  final engines = record['engines'];
  if (engines is List) {
    for (final engine in engines) {
      if (engine is Map) out.addAll(_stringList(engine['models']));
    }
  }
  out.addAll(_stringList(record['models']));
  return out.toList()..sort();
}

List<String> _stringList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String && item.isNotEmpty) item,
      ]
    : const [];

/// Whether [id] is a grid id and not a path.
bool _isGridId(String id) =>
    id.isNotEmpty && id.length <= 64 && RegExp(r'^[\w-]+$').hasMatch(id);
