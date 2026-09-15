import '../../../core/process_liveness.dart';
import '../../../infrastructure/state/models/engine_run.dart';

// Re-exported because this is where every caller has always found it.
export '../../../core/process_liveness.dart' show pidIsAlive;

/// Engine run-record liveness helpers, shared by the run controller (adopt on
/// restart) and the serving-union provider (list what's live). A grid's dir can
/// hold stale records from prior sessions beside the live one, so both pick the
/// record whose process still answers rather than the first on disk.

/// The first still-running engine among [records], or null when none is alive.
EngineRunRecord? firstLiveRun(List<EngineRunRecord> records) {
  for (final record in records) {
    if (pidIsAlive(record.pid)) return record;
  }
  return null;
}
