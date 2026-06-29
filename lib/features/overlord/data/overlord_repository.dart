import 'models/overlord_snapshot.dart';

/// The dashboard's data source. The UI depends only on this; a fake impl drives
/// it today and a real Overlord client (HTTP/WS/SSE) can drop in later without
/// touching a single widget.
abstract interface class OverlordRepository {
  /// A live stream of dashboard frames. Emits an initial snapshot immediately,
  /// then a new one on every refresh tick.
  Stream<OverlordSnapshot> watch();
}
