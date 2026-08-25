import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where one tracked event got to.
enum AnalyticsEventStatus {
  /// In the queue: never sent, or sent and waiting on a retry.
  queued,

  /// The server took it.
  sent,

  /// The server refused it (a 4xx that isn't 408/429) — our instrumentation is
  /// wrong, not the network.
  refused,

  /// Never reached the wire: an invalid name, or pushed out of a full queue.
  dropped,
}

/// One tracked event as the Tracking tab shows it: what was tracked, what went
/// over the wire, and how it ended.
class AnalyticsLogEntry {
  const AnalyticsLogEntry({
    required this.id,
    required this.name,
    required this.params,
    required this.queuedAt,
    required this.status,
    this.attempts = 0,
    this.payload,
    this.note,
    this.settledAt,
  });

  final int id;
  final String name;

  /// The params as the call site passed them — before the context and identity
  /// are merged in. [payload] is what actually went out.
  final Map<String, Object?> params;

  final DateTime queuedAt;
  final AnalyticsEventStatus status;

  /// How many times this event has been put on the wire. Two or more means the
  /// endpoint failed and the queue retried, which is the thing this tab exists
  /// to make visible.
  final int attempts;

  /// The exact JSON body sent, or null before the first attempt.
  final String? payload;

  /// Why it ended the way it did, when the status alone doesn't say.
  final String? note;

  final DateTime? settledAt;

  /// How long from being tracked to being settled, or null while it waits.
  Duration? get took => settledAt?.difference(queuedAt);

  AnalyticsLogEntry copyWith({
    AnalyticsEventStatus? status,
    int? attempts,
    String? payload,
    String? note,
    DateTime? settledAt,
  }) => AnalyticsLogEntry(
    id: id,
    name: name,
    params: params,
    queuedAt: queuedAt,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    payload: payload ?? this.payload,
    note: note ?? this.note,
    settledAt: settledAt ?? this.settledAt,
  );
}

/// The recorder the analytics queue reports to.
///
/// An interface so the queue stays free of Riverpod and can be driven by a fake
/// — the same seam `CommandLogNotifier` gives the CLI service.
abstract interface class AnalyticsLog {
  /// Records an event entering the queue; returns its id for the calls below.
  int queued(String name, Map<String, Object?> params, DateTime at);

  /// Records that [payload] has just gone on the wire for entry [id]. Called
  /// once per attempt, so the count reads as retries.
  void attempted(int id, String payload);

  /// Records how entry [id] ended.
  void settled(int id, AnalyticsEventStatus status, {String? note});
}

/// Records nothing — the default, so the queue can run with no tab watching.
class NoopAnalyticsLog implements AnalyticsLog {
  const NoopAnalyticsLog();

  @override
  int queued(String name, Map<String, Object?> params, DateTime at) => 0;

  @override
  void attempted(int id, String payload) {}

  @override
  void settled(int id, AnalyticsEventStatus status, {String? note}) {}
}

/// In-memory ring buffer of recent events, newest first. Fed by
/// `QueuedAnalytics`; read by the Tracking tab.
///
/// In memory only, and deliberately: this is a window onto a queue that is
/// itself in memory, and a stream that measures the app must not become a
/// second thing the app writes to disk on every click.
final analyticsLogProvider =
    NotifierProvider<AnalyticsLogNotifier, List<AnalyticsLogEntry>>(
      AnalyticsLogNotifier.new,
    );

class AnalyticsLogNotifier extends Notifier<List<AnalyticsLogEntry>>
    implements AnalyticsLog {
  static const int _maxEntries = 200;
  int _seq = 0;

  @override
  List<AnalyticsLogEntry> build() => const [];

  @override
  int queued(String name, Map<String, Object?> params, DateTime at) {
    final id = ++_seq;
    final entry = AnalyticsLogEntry(
      id: id,
      name: name,
      // Copied, so a caller that reuses its map can't rewrite history here.
      params: Map<String, Object?>.unmodifiable(params),
      queuedAt: at,
      status: AnalyticsEventStatus.queued,
    );
    _schedule(
      () => state = [entry, ...state].take(_maxEntries).toList(growable: false),
    );
    return id;
  }

  @override
  void attempted(int id, String payload) => _update(
    id,
    (entry) => entry.copyWith(attempts: entry.attempts + 1, payload: payload),
  );

  @override
  void settled(int id, AnalyticsEventStatus status, {String? note}) => _update(
    id,
    (entry) =>
        entry.copyWith(status: status, note: note, settledAt: DateTime.now()),
  );

  void clear() => _schedule(() => state = const []);

  void _update(int id, AnalyticsLogEntry Function(AnalyticsLogEntry) change) =>
      _schedule(() {
        state = [
          for (final entry in state)
            if (entry.id == id) change(entry) else entry,
        ];
      });

  /// Applies the mutation on the next microtask, never synchronously — an event
  /// is tracked from inside other providers' work (a shell section changing, a
  /// login finishing), and Riverpod forbids writing one provider's state during
  /// another's build. Same reason, and same shape, as [CommandLogNotifier].
  ///
  /// The deferral is what makes the mounted check necessary: the container can
  /// be torn down between scheduling and running, and writing `state` then
  /// throws into a microtask with no caller to catch it.
  void _schedule(void Function() update) => Future.microtask(() {
    if (!ref.mounted) return;
    update();
  });
}
