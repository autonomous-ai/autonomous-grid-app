import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../logging/app_log.dart';
import 'analytics.dart';
import 'analytics_client.dart';
import 'analytics_config.dart';
import 'analytics_event.dart';
import 'analytics_identity.dart';
import 'analytics_log.dart';

/// Who is signed in, asked fresh at track time — a session that starts signed
/// out and ends signed in must not report the whole visit as anonymous.
typedef AnalyticsUserLookup = ({String? id, String? email}) Function();

/// [Analytics] that queues in memory and sends serially, with retry.
///
/// Autonomous Analytics takes one event per request, so this is a queue with a
/// worker rather than a batcher. The order of the three failure paths is the
/// point: a **transport** failure keeps the event and backs off, a **refusal**
/// drops it (resending changes nothing), and a queue that grows past
/// `AnalyticsLimits.queueCap` drops its oldest — the newest events are the ones
/// that describe what is happening now.
///
/// Not persisted across launches: a machine quit while offline loses what was
/// still queued. That is a deliberate limit, not an oversight — the alternative
/// is a spool file that outlives an uninstall.
class QueuedAnalytics implements Analytics {
  QueuedAnalytics({
    required AnalyticsClient client,
    required AnalyticsIdentityStore identity,
    required Future<AnalyticsContext> context,
    required AnalyticsUserLookup user,
    AppLog log = const NoopAppLog(),
    AnalyticsLog recorder = const NoopAnalyticsLog(),
    DateTime Function() clock = DateTime.now,
  }) : _client = client,
       _identity = identity,
       _context = context,
       _user = user,
       _log = log,
       _recorder = recorder,
       _clock = clock;

  final AnalyticsClient _client;
  final AnalyticsIdentityStore _identity;
  final Future<AnalyticsContext> _context;
  final AnalyticsUserLookup _user;
  final AppLog _log;
  final AnalyticsLog _recorder;
  final DateTime Function() _clock;

  /// Each queued event beside the id of its row in the Tracking tab, so the
  /// row can be settled without the wire model carrying a debug field.
  final Queue<({AnalyticsEvent event, int logId})> _queue =
      Queue<({AnalyticsEvent event, int logId})>();

  AnalyticsContext? _resolvedContext;
  Future<void>? _draining;
  Timer? _retryTimer;
  Duration _retryDelay = AnalyticsLimits.retryDelay;
  bool _warnedFull = false;
  bool _closed = false;

  @override
  void track(String name, {Map<String, Object?> params = const {}}) {
    if (_closed) return;
    final now = _clock();
    if (!analyticsEventNamePattern.hasMatch(name)) {
      const reason = 'names must be snake_case, 3-64 characters';
      // Recorded before it is refused, so the Tracking tab shows the mistake
      // rather than nothing at all — an event that never lands is exactly what
      // somebody would open that tab to explain.
      _recorder.settled(
        _recorder.queued(name, params, now),
        AnalyticsEventStatus.dropped,
        note: reason,
      );
      _log.warn('analytic', 'Ignored event "$name" — $reason');
      return;
    }
    try {
      final ids = _identity.touch(now);
      final user = _user();
      _queue.add((
        event: AnalyticsEvent(
          name: name,
          params: params,
          at: now,
          identity: AnalyticsIdentity(
            pseudoId: ids.pseudoId,
            sessionId: ids.sessionId,
            userId: user.id,
            userEmail: user.email,
          ),
        ),
        logId: _recorder.queued(name, params, now),
      ));
      _trim();
      unawaited(_pump());
    } on Object catch (error) {
      _log.warn('analytic', 'Dropped event "$name"', error: error);
    }
  }

  @override
  Future<void> flush() {
    _cancelRetry();
    return _pump();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _cancelRetry();
    await _pump().timeout(AnalyticsLimits.closeDeadline, onTimeout: () {});
    _closed = true;
    _client.dispose();
  }

  /// Drops the oldest events once the queue is over its cap, warning once per
  /// outage so a plane ride doesn't fill the log with the same line.
  void _trim() {
    if (_queue.length <= AnalyticsLimits.queueCap) return;
    while (_queue.length > AnalyticsLimits.queueCap) {
      _recorder.settled(
        _queue.removeFirst().logId,
        AnalyticsEventStatus.dropped,
        note: 'the queue was full',
      );
    }
    if (_warnedFull) return;
    _warnedFull = true;
    _log.warn(
      'analytic',
      'Event queue full (${AnalyticsLimits.queueCap}) — dropping the oldest; '
          'the analytics endpoint has been unreachable for a while',
    );
  }

  /// One drain at a time: concurrent callers share the in-flight future rather
  /// than starting a second worker on the same queue.
  Future<void> _pump() {
    if (_closed || _queue.isEmpty) return Future.value();
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    final context = _resolvedContext ??= await _context.catchError(
      (Object _) => AnalyticsContext.unknown,
    );
    while (_queue.isNotEmpty && !_closed) {
      final queued = _queue.first;
      final event = queued.event;
      final AnalyticsSendResult result;
      try {
        final payload = analyticsPayload(event, context);
        _recorder.attempted(queued.logId, jsonEncode(payload));
        result = await _client.send(payload);
      } on Object catch (error, stackTrace) {
        // The client's contract says it never throws; if it ever does, the
        // queue must not be left spinning on the same event forever.
        _queue.removeFirst();
        _recorder.settled(
          queued.logId,
          AnalyticsEventStatus.dropped,
          note: '$error',
        );
        _log.failure(
          'analytic',
          'Send failed for "${event.name}"',
          error: error,
          stackTrace: stackTrace,
        );
        continue;
      }
      switch (result) {
        case AnalyticsSendResult.sent:
          _queue.removeFirst();
          _recorder.settled(queued.logId, AnalyticsEventStatus.sent);
          _retryDelay = AnalyticsLimits.retryDelay;
          _warnedFull = false;
        case AnalyticsSendResult.rejected:
          _queue.removeFirst();
          _recorder.settled(
            queued.logId,
            AnalyticsEventStatus.refused,
            note: 'the server refused it',
          );
          _log.warn(
            'analytic',
            'Server refused "${event.name}" — the event was dropped',
          );
        case AnalyticsSendResult.retry:
          _scheduleRetry();
          return;
      }
    }
  }

  void _scheduleRetry() {
    if (_retryTimer != null || _closed) return;
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      unawaited(_pump());
    });
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > AnalyticsLimits.retryDelayMax
        ? AnalyticsLimits.retryDelayMax
        : doubled;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}
