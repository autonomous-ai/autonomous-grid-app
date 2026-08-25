import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../features/auth/logic/session_controller.dart';
import '../logging/app_log.dart';
import 'analytics_client.dart';
import 'analytics_config.dart';
import 'analytics_event.dart';
import 'analytics_identity.dart';
import 'analytics_service.dart';

/// The ids every event carries, from `~/.grid/app/analytics.json`. Overridden
/// in tests with a temp-file-backed instance.
final analyticsIdentityStoreProvider = Provider<AnalyticsIdentityStore>(
  (ref) => AnalyticsIdentityStore(),
);

/// The machine and build an event happened on, resolved once per launch.
///
/// Never fails: a version lookup that throws costs those fields, not the
/// stream. The queue awaits this once, before its first send, so the first
/// event of a launch already carries the version rather than racing it.
final analyticsContextProvider = FutureProvider<AnalyticsContext>((ref) async {
  var version = '';
  var build = '';
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
    build = info.buildNumber;
  } on Object {
    // A bundle we can't read is worth an anonymous version, not a lost event.
  }
  return AnalyticsContext(
    platform: Platform.operatingSystem,
    appVersion: version,
    appBuild: build,
    osVersion: Platform.operatingSystemVersion,
    arch: Abi.current().toString(),
    locale: Platform.localeName,
    release: kReleaseMode,
  );
});

/// The app's analytics sink.
///
/// [NoopAnalytics] whenever tracking is off — the environment muted it, the
/// code is under `flutter test`, or the user opted out in
/// `~/.grid/app/analytics.json` — so a muted app and a test run open no sockets
/// at all rather than queueing into a void.
final analyticsProvider = Provider<Analytics>((ref) {
  // The environment is asked first, and on purpose: under `flutter test` this
  // returns before anything reads `~/.grid`, so a logic test that happens to
  // track an event touches neither the network nor a real grid home (§8).
  final config = AnalyticsConfig.resolve();
  if (!config.enabled) return const NoopAnalytics();
  final store = ref.watch(analyticsIdentityStoreProvider);
  if (store.optedOut) return const NoopAnalytics();
  final analytics = QueuedAnalytics(
    client: HttpAnalyticsClient(config),
    identity: store,
    context: ref.read(analyticsContextProvider.future),
    user: () => _signedInUser(ref),
    log: ref.read(appLogProvider),
  );
  // Best-effort: a provider container torn down mid-flush is the app already
  // going away, and `close` is time-boxed anyway.
  ref.onDispose(() => unawaited(analytics.close()));
  return analytics;
});

/// The signed-in account as the wire wants it, read fresh per event.
///
/// `google_sub` rather than the email is the id: it is stable, it is not
/// something a person typed, and it survives an address change. The email rides
/// along as a param because the website sends it too — without it the same
/// person can't be matched across the two streams.
({String? id, String? email}) _signedInUser(Ref ref) {
  final credentials = ref.read(sessionProvider);
  final sub = credentials.user['google_sub'];
  return (id: sub is String ? sub : null, email: credentials.userEmail);
}
