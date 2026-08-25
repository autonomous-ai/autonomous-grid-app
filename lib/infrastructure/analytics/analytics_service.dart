import 'dart:async';
import 'dart:collection';

import '../logging/app_log.dart';
import 'analytics_client.dart';
import 'analytics_config.dart';
import 'analytics_event.dart';
import 'analytics_identity.dart';

/// The app's behavioural-event sink.
///
/// Every call site talks to this, never to the transport underneath, so
/// tracking can be muted (opt-out, a test run, a build with no key) by handing
/// out a [NoopAnalytics] instead of by checking a flag at each call site.
///
/// Nothing here throws and nothing here is awaited by the UI: an analytics
/// problem must never be something the user finds out about.
abstract interface class Analytics {
  /// Queue one event. [name] must be `snake_case`
  /// (`analyticsEventNamePattern`) or it is dropped with a warning in the app
  /// log — the backend would accept it silently and leave the stream
  /// unqueryable.
  ///
  /// [params] is free-form, but it is a *product* record, not a debug dump:
  /// never put message text, prompts, file contents or absolute paths in it.
  void track(String name, {Map<String, Object?> params});

  /// Send whatever is queued now, instead of waiting on the retry timer.
  Future<void> flush();

  /// Final, time-boxed drain, then release the connection. Called when the app
  /// quits; the instance is spent afterwards.
  Future<void> close();
}

/// Does nothing, for a muted app and for tests.
class NoopAnalytics implements Analytics {
  const NoopAnalytics();

  @override
  void track(String name, {Map<String, Object?> params = const {}}) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

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
    DateTime Function() clock = DateTime.now,
  }) : _client = client,
       _identity = identity,
       _context = context,
       _user = user,
       _log = log,
       _clock = clock;

  final AnalyticsClient _client;
  final AnalyticsIdentityStore _identity;
  final Future<AnalyticsContext> _context;
  final AnalyticsUserLookup _user;
  final AppLog _log;
  final DateTime Function() _clock;

  final Queue<AnalyticsEvent> _queue = Queue<AnalyticsEvent>();

  AnalyticsContext? _resolvedContext;
  Future<void>? _draining;
  Timer? _retryTimer;
  Duration _retryDelay = AnalyticsLimits.retryDelay;
  bool _warnedFull = false;
  bool _closed = false;

  @override
  void track(String name, {Map<String, Object?> params = const {}}) {
    if (_closed) return;
    if (!analyticsEventNamePattern.hasMatch(name)) {
      _log.warn(
        'analytic',
        'Ignored event "$name" — names must be snake_case, 3-64 chars',
      );
      return;
    }
    try {
      final now = _clock();
      final ids = _identity.touch(now);
      final user = _user();
      _queue.add(
        AnalyticsEvent(
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
      );
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
      _queue.removeFirst();
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
      final event = _queue.first;
      final AnalyticsSendResult result;
      try {
        result = await _client.send(analyticsPayload(event, context));
      } on Object catch (error, stackTrace) {
        // The client's contract says it never throws; if it ever does, the
        // queue must not be left spinning on the same event forever.
        _queue.removeFirst();
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
          _retryDelay = AnalyticsLimits.retryDelay;
          _warnedFull = false;
        case AnalyticsSendResult.rejected:
          _queue.removeFirst();
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
