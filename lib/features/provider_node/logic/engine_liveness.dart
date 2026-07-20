import 'dart:io';

import '../../../infrastructure/state/models/engine_run.dart';

/// Engine run-record liveness helpers, shared by the run controller (adopt on
/// restart) and the serving-union provider (list what's live). A grid's dir can
/// hold stale records from prior sessions beside the live one, so both pick the
/// record whose process still answers rather than the first on disk.

/// True if [pid] names a live process. POSIX `kill -0` probes existence without
/// signalling; where it's unavailable we can't tell, so assume alive (every stop
/// path `grid leave`s regardless).
bool pidIsAlive(int? pid) {
  if (pid == null) return false;
  if (Platform.isWindows) return true;
  try {
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } on ProcessException {
    return true;
  }
}

/// The first still-running engine among [records], or null when none is alive.
EngineRunRecord? firstLiveRun(List<EngineRunRecord> records) {
  for (final record in records) {
    if (pidIsAlive(record.pid)) return record;
  }
  return null;
}
