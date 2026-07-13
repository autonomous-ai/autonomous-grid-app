import 'dart:async';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';

/// Public Sparkle appcast the macOS build polls for a newer signed release.
/// Injected at build time (`--dart-define=GRID_APPCAST_URL=…`) so the host can
/// change per environment without a code edit; empty = auto-update disabled.
///
/// The feed must be reachable without auth: Sparkle downloads the enclosure,
/// verifies its EdDSA signature against `SUPublicEDKey` (macOS `Info.plist`),
/// then swaps the app in place and relaunches. CI publishes the appcast + the
/// signed `.dmg` — see `.github/workflows/release.yml`.
const String kAppcastFeedUrl = String.fromEnvironment('GRID_APPCAST_URL');

/// The visible outcome of a "Check for updates" so an explicit tap always
/// resolves to feedback — Sparkle's own dialog only appears when the check
/// succeeds, so a silent native no-op (a debug build, a stalled feed) used to
/// read as "nothing happened". Emitted on [AppUpdaterService.status].
sealed class UpdateStatus {
  const UpdateStatus();
}

/// A check is in flight (emitted the moment the user taps, before the native
/// side responds — so even a check that never fires still shows *something*).
class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

/// A newer build exists; Sparkle also shows its own install prompt.
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.version);
  final String? version;
}

/// The check completed and this build is current.
class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate();
}

/// The check failed (bad feed, network, signature, or a native error).
class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message);
  final String message;
}

/// This build can't auto-update at all — no appcast feed was baked in (a local
/// / dev build), so there is nothing to check against. Emitted instead of doing
/// nothing, because the macOS "Check for Updates…" menu item always exists and
/// a silent no-op reads as a broken app.
class UpdateUnsupported extends UpdateStatus {
  const UpdateUnsupported();
}

/// Thin wrapper over the `auto_updater` (Sparkle / WinSparkle) plugin. macOS-only
/// for now — Windows is deferred until its signing key + installer exist — and a
/// no-op elsewhere so callers never have to branch on the platform.
///
/// Registers as a Sparkle [UpdaterListener] so every check outcome is both
/// logged (to `~/.grid/logs/app.log`, for diagnosing "it did nothing") and
/// pushed to [status] for the UI to surface as a toast.
class AppUpdaterService with UpdaterListener {
  AppUpdaterService({AppLog log = const NoopAppLog()}) : _log = log;

  final AppLog _log;

  /// Sparkle's minimum check interval is 3600s; once a day is plenty for the
  /// scheduled timer since we also check silently on launch and on demand.
  static const int _dailySeconds = 86400;

  /// Bridge to the native macOS app-menu "Check for Updates…" item. The Swift
  /// side (see `AppDelegate.checkForUpdatesFromMenu`) invokes `checkForUpdates`
  /// on this channel so the menu and the in-app account menu share one updater.
  static const MethodChannel _menuChannel = MethodChannel('grid/app_updater');

  final StreamController<UpdateStatus> _status =
      StreamController<UpdateStatus>.broadcast();

  UpdateStatus? _last;

  /// Outcomes of update checks, so the UI can toast "checking / up to date /
  /// available / failed". The latest outcome is replayed to new subscribers:
  /// the launch check runs before the first frame, and without a replay its
  /// "update available" would be emitted into the void and never shown.
  Stream<UpdateStatus> get status async* {
    final last = _last;
    if (last != null) yield last;
    yield* _status.stream;
  }

  /// True on the platforms that ship the updater UI (and the "Check for
  /// Updates…" app-menu item). The in-app menu mirrors this so both entry
  /// points exist together — a build with no feed still answers, with
  /// [UpdateUnsupported].
  bool get isSupported => Platform.isMacOS;

  /// True when a feed is also configured, i.e. a check can actually run. Gates
  /// every Sparkle call so callers don't branch on the platform.
  bool get isEnabled => isSupported && kAppcastFeedUrl.isNotEmpty;

  /// Points Sparkle at the feed and schedules its periodic background checks. A
  /// no-op when the updater isn't enabled.
  ///
  /// Deliberately does *not* check right now: on a first run the app is busy
  /// installing an engine and downloading a model, and Sparkle's "a new version
  /// is available" dialog would land on top of that — asking the user to restart
  /// the very app that is mid-download. The launch check is fired from the app
  /// shell instead ([checkInBackground]), which is only reached once setup is
  /// done or skipped.
  Future<void> init() async {
    if (!isEnabled) return;
    autoUpdater.addListener(this);
    await autoUpdater.setFeedURL(kAppcastFeedUrl);
    await autoUpdater.setScheduledCheckInterval(_dailySeconds);
  }

  /// Silent check — Sparkle surfaces its update prompt only when a newer build
  /// exists (no "you're up to date" dialog). Used on launch.
  Future<void> checkInBackground() async {
    if (!isEnabled) return;
    await _guard(() => autoUpdater.checkForUpdates(inBackground: true));
  }

  /// User-initiated check — shows Sparkle's UI even when already up to date, so
  /// an explicit "Check for updates" tap always gives feedback. Emits
  /// [UpdateChecking] up front so the UI acknowledges the tap even if the native
  /// side never responds, and [UpdateUnsupported] when this build has no feed —
  /// a tap must never resolve to silence.
  Future<void> checkForUpdates() async {
    _log.info('update', 'User-initiated update check');
    if (!isEnabled) {
      _log.info('update', 'Updater disabled — this build has no update feed');
      _emit(const UpdateUnsupported());
      return;
    }
    _emit(const UpdateChecking());
    await _guard(() => autoUpdater.checkForUpdates(inBackground: false));
  }

  /// Runs a Sparkle call, turning a thrown native error into a logged
  /// [UpdateFailed] instead of an unhandled async error the user never sees.
  Future<void> _guard(Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (e, st) {
      _log.failure('update', 'Update check threw', error: e, stackTrace: st);
      _emit(UpdateFailed('$e'));
    }
  }

  /// Wire the native macOS "Grid ▸ Check for Updates…" menu item to
  /// [checkForUpdates]. Only macOS ships that menu item, so this is a no-op
  /// elsewhere; on a build with no feed the tap resolves to [UpdateUnsupported]
  /// rather than to silence.
  void bindNativeMenu() {
    if (!Platform.isMacOS) return;
    _menuChannel.setMethodCallHandler((call) async {
      if (call.method == 'checkForUpdates') await checkForUpdates();
    });
  }

  // ── Sparkle listener callbacks: log every outcome and mirror it to [status].
  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) =>
      _log.info('update', 'Sparkle checking the feed');

  @override
  void onUpdaterUpdateAvailable(AppcastItem? item) {
    final version = item?.displayVersionString ?? item?.versionString;
    _log.info('update', 'Update available: ${version ?? 'unknown'}');
    _emit(UpdateAvailable(version));
  }

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    _log.info('update', 'No update available — already current');
    _emit(const UpdateUpToDate());
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    final message = error?.message ?? 'unknown error';
    _log.failure('update', 'Updater error: $message');
    _emit(UpdateFailed(message));
  }

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? item) => _log.info(
      'update', 'Update downloaded: ${item?.displayVersionString ?? ''}');

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? item) =>
      _log.info('update', 'Quitting to install update');

  void _emit(UpdateStatus status) {
    _last = status;
    if (!_status.isClosed) _status.add(status);
  }
}

/// The app-update seam. Overridden in `main` with the one instance that owns the
/// Sparkle listener + log; the default (unoverridden) instance is inert since no
/// feed is configured in tests.
final appUpdaterServiceProvider = Provider<AppUpdaterService>(
  (ref) => AppUpdaterService(),
);

/// Stream of check outcomes for the UI to toast — a tap never silently no-ops.
/// Empty until the first check runs.
final appUpdateStatusProvider = StreamProvider<UpdateStatus>(
  (ref) => ref.watch(appUpdaterServiceProvider).status,
);
