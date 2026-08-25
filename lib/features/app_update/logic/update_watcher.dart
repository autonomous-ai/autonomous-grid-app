import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/update_dismiss_store.dart';
import 'app_updater_service.dart';
import 'appcast_feed.dart';

/// How often the app looks for a new release on its own.
///
/// Sparkle's floor is an hour; this lane has none, because it is one small GET
/// against a static file GitHub already serves to everyone. Half an hour is
/// short enough that a release published while someone is working reaches them
/// the same session, which is the whole reason this lane exists — Sparkle's own
/// check is a day apart and can land on a machine that has already been shut
/// down for the evening.
const Duration kUpdatePollInterval = Duration(minutes: 30);

/// The release this app should offer, or null when there is nothing to offer.
///
/// Null is the resting state and covers everything: no feed baked into this
/// build, nothing newer published, or the user closed the banner on this
/// release. The banner draws only for a non-null value, so nothing else has to
/// ask "should I be visible?".
final updateWatcherProvider = NotifierProvider<UpdateWatcher, AppcastRelease?>(
  UpdateWatcher.new,
);

/// The app's own lane for noticing a new release, running beside Sparkle's
/// rather than instead of it.
///
/// Two lanes on purpose. This one is fast (half-hourly) and draws the app's own
/// banner; Sparkle's is slow, shows its own dialog, and is code that has been
/// shipping for years. If this lane breaks — a bad parse, a thrown provider, a
/// timer that never starts — Sparkle still tells the user, which is the one
/// outcome a home-grown updater must never take away. That is also why every
/// failure here resolves to "no banner" and never to a thrown error: the quiet
/// half of a pair is recoverable, a crash loop is not.
class UpdateWatcher extends Notifier<AppcastRelease?> {
  Timer? _timer;

  /// The build the banner was last closed on. Held in memory so a poll every
  /// half hour doesn't re-read the file, and written through on close.
  int? _dismissed;

  @override
  AppcastRelease? build() => null;

  /// Begin watching: look once now, then every [kUpdatePollInterval].
  ///
  /// Called from the app shell rather than from [build] or from `main`, for the
  /// same reason the Sparkle launch check is: a first-run machine is busy
  /// installing an engine and downloading a model, and the shell is only
  /// reached once that is done or skipped. Calling it twice is harmless.
  void start() {
    if (_timer != null) return;
    if (!_enabled) {
      _log.info('update', 'Update watcher idle — this build has no feed');
      return;
    }
    _dismissed = ref.read(updateDismissStoreProvider).load();
    _timer = Timer.periodic(kUpdatePollInterval, (_) => unawaited(_poll()));
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    unawaited(_poll());
  }

  /// Close the banner for this release. A later one opens it again on its own.
  void dismiss() {
    final release = state;
    if (release == null) return;
    _dismissed = release.build;
    ref.read(updateDismissStoreProvider).save(release.build);
    _log.info('update', 'Banner closed on ${release.shortVersion}');
    state = null;
  }

  /// One look at the feed. Never throws: a failure leaves the banner as it was
  /// and is written to the log, where "it never told me" can be diagnosed.
  Future<void> _poll() async {
    try {
      final installed = await _installedBuild();
      if (installed == null) {
        // Without our own build number there is nothing to compare against, and
        // guessing would either nag forever or hide a real release. Sparkle's
        // lane covers this case, which is precisely why it is still running.
        _log.failure('update', "Can't read this build's number — skipping");
        return;
      }
      final release = updateFor(await _fetchFeed(), installedBuild: installed);
      if (release == null) {
        state = null;
        return;
      }
      if (_dismissed != null && release.build <= _dismissed!) return;
      if (state?.build == release.build) return;
      _log.info('update', 'Update available: ${release.shortVersion}');
      state = release;
    } on Object catch (e, st) {
      _log.failure('update', 'Update check failed', error: e, stackTrace: st);
    }
  }

  /// The appcast this build polls, as text.
  Future<String> _fetchFeed() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(_feedUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'feed answered ${response.statusCode}',
          uri: request.uri,
        );
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  /// This build's `CFBundleVersion`, or null when it isn't a number.
  Future<int?> _installedBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber);
  }

  /// The same feed Sparkle is pointed at, arch token resolved for this CPU.
  String get _feedUrl => resolveAppcastArch(kAppcastFeedUrl, Abi.current());

  /// A feed is the whole condition: a Linux build and a local dev build both
  /// have none, and both should sit quiet rather than poll a URL that isn't
  /// there.
  bool get _enabled => kAppcastFeedUrl.isNotEmpty;

  AppLog get _log => ref.read(appLogProvider);
}
