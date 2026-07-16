import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/fake_overlord_repository.dart';
import '../data/models/overlord_snapshot.dart';
import '../data/overlord_repository.dart';

/// The dashboard's data source. Bound to the fake driver today; point this at a
/// real Overlord client and every panel updates with no other change.
final overlordRepositoryProvider = Provider<OverlordRepository>(
  (ref) => FakeOverlordRepository(),
);

/// Live dashboard frames. Auto-disposed so the driver stops the moment the
/// Overlord section is left.
final overlordSnapshotProvider = StreamProvider.autoDispose<OverlordSnapshot>(
  (ref) => ref.watch(overlordRepositoryProvider).watch(),
);

/// Wall-clock tick for the header (`04:25:30`), once per second.
final overlordClockProvider = StreamProvider.autoDispose<DateTime>((
  ref,
) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(
    const Duration(seconds: 1),
    (_) => DateTime.now(),
  );
});
