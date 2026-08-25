import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where behavioural events go, whether they go at all, and under what limits.
///
/// The destination is **Autonomous Analytics** — the same event stream the
/// website reports into (`src/services/Tracking/AutonomousAnalytic` in web-v16),
/// with this app's own write key. Sharing the destination is the point: someone
/// who read the site and then installed Grid is one funnel, not two datasets
/// that can never be joined.
///
/// The key is a *write* key, not a secret. The website ships the same kind of
/// key in its public JS bundle (`NEXT_PUBLIC_AUTONOMOUS_ANALYTICS_ID`), a
/// desktop binary can be unpacked either way, and it only lets the holder append
/// events. Treat it as public and rotate it server-side if it is ever abused.
class AnalyticsConfig {
  const AnalyticsConfig({
    required this.endpoint,
    required this.writeKey,
    required this.enabled,
  });

  /// The full `…/api/v1/event_tracking` URL one event is POSTed to. Autonomous
  /// Analytics takes a single event per request — there is no batch route — so
  /// the queue sends serially rather than in batches.
  final Uri endpoint;

  /// Sent verbatim as `Authorization`, with no `Bearer` prefix — that is what
  /// the web client does and what the server reads.
  final String writeKey;

  /// False when the environment muted the app, when there is no key to send
  /// with, or under `flutter test`. The user's own opt-out is checked
  /// separately, by `analyticsProvider` — this answer must be reachable
  /// *without* reading `~/.grid`, so a test run touches no grid home at all.
  final bool enabled;

  /// Env var / `--dart-define` names. The URL and key overrides are dev-only
  /// (like [AppEnvironment]) so a shipped build always reports to production;
  /// [disableEnvKey] is honoured everywhere, because a user who wants to be
  /// left alone has to be able to say so in a release build.
  static const String urlEnvKey = 'GRID_ANALYTICS_URL';
  static const String keyEnvKey = 'GRID_ANALYTICS_KEY';
  static const String disableEnvKey = 'GRID_ANALYTICS_DISABLED';

  // `String.fromEnvironment` needs a const literal, so the names above can't be
  // used here — keep the two in step by hand.
  static const String _urlDefine = String.fromEnvironment('GRID_ANALYTICS_URL');
  static const String _keyDefine = String.fromEnvironment('GRID_ANALYTICS_KEY');

  static const String _defaultBaseUrl =
      'https://autonomous-analytics-qffztaoryq-uc.a.run.app/api/v1';
  static const String _path = 'event_tracking';

  /// This app's Autonomous Analytics write key — its own, not the website's, so
  /// the two streams stay separable at the source.
  static const String _defaultWriteKey = 'tBCs0oLwgFgf1borYn54cjHz4fvWahyV';

  /// The live configuration, from the environment alone.
  static AnalyticsConfig resolve() {
    final base = (_devOverride(urlEnvKey) ?? _defaultBaseUrl).replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final key = _devOverride(keyEnvKey) ?? _defaultWriteKey;
    return AnalyticsConfig(
      endpoint: Uri.parse('$base/$_path'),
      writeKey: key,
      enabled: key.isNotEmpty && !_muted && !_underTest,
    );
  }

  /// True when `GRID_ANALYTICS_DISABLED` is set to anything truthy.
  static bool get _muted {
    final value = Platform.environment[disableEnvKey]?.toLowerCase().trim();
    return value == '1' || value == 'true' || value == 'yes';
  }

  /// The test runner sets `FLUTTER_TEST`. Tests are offline and deterministic
  /// (conventions §8), and a controller under test that happens to track an
  /// event must not open a socket to do it.
  static bool get _underTest =>
      Platform.environment.containsKey('FLUTTER_TEST');

  /// [key]'s override — `--dart-define` first, then the process env — ignored
  /// in release so a shipped build can only ever report to production.
  static String? _devOverride(String key) {
    if (kReleaseMode) return null;
    final define = switch (key) {
      urlEnvKey => _urlDefine,
      keyEnvKey => _keyDefine,
      _ => '',
    };
    if (define.isNotEmpty) return define;
    final value = Platform.environment[key];
    return (value != null && value.isNotEmpty) ? value : null;
  }
}

/// The limits the queue and the payload are held to.
///
/// [sessionIdle] matches the website's 15 minutes on purpose: a "visit" has to
/// mean the same span on both sides or the two streams can't be compared. The
/// rest are this app's own — a desktop app that is quit offline and reopened on
/// a plane needs a bounded queue and a backoff, which a page that unloads after
/// a few minutes never did.
class AnalyticsLimits {
  const AnalyticsLimits._();

  /// Events kept while the server is unreachable. Past this the oldest go —
  /// a full queue is a signal, and the newest events describe it best.
  static const int queueCap = 500;

  /// Params per event, and the length of any one string value. The backend
  /// truncates and drops on its own; doing it here keeps what we send and what
  /// lands identical, so a value read back in analysis is the value we meant.
  static const int paramsMaxKeys = 40;
  static const int paramsMaxStringLength = 500;

  /// How long a visit survives without an event before a new one starts.
  static const Duration sessionIdle = Duration(minutes: 15);

  static const Duration requestTimeout = Duration(seconds: 10);

  /// First retry delay, doubled up to [retryDelayMax] while sends keep failing.
  static const Duration retryDelay = Duration(seconds: 2);
  static const Duration retryDelayMax = Duration(minutes: 2);

  /// How long a quit waits for the queue to drain. A wedged network must never
  /// be what keeps the window on screen after the user pressed ⌘Q.
  static const Duration closeDeadline = Duration(seconds: 3);
}
