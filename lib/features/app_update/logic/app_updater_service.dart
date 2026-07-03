import 'dart:async';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Public Sparkle appcast the macOS build polls for a newer signed release.
/// Injected at build time (`--dart-define=GRID_APPCAST_URL=…`) so the host can
/// change per environment without a code edit; empty = auto-update disabled.
///
/// The feed must be reachable without auth: Sparkle downloads the enclosure,
/// verifies its EdDSA signature against `SUPublicEDKey` (macOS `Info.plist`),
/// then swaps the app in place and relaunches. CI publishes the appcast + the
/// signed `.dmg` — see `.github/workflows/release.yml`.
const String kAppcastFeedUrl = String.fromEnvironment('GRID_APPCAST_URL');

/// Thin wrapper over the `auto_updater` (Sparkle / WinSparkle) plugin. macOS-only
/// for now — Windows is deferred until its signing key + installer exist — and a
/// no-op elsewhere so callers never have to branch on the platform.
class AppUpdaterService {
  const AppUpdaterService();

  /// Sparkle's minimum check interval is 3600s; once a day is plenty for the
  /// scheduled timer since we also check silently on launch and on demand.
  static const int _dailySeconds = 86400;

  /// True when a feed is configured on a platform the updater supports. Gates
  /// every action so callers don't branch on the platform.
  bool get isEnabled => Platform.isMacOS && kAppcastFeedUrl.isNotEmpty;

  /// Points Sparkle at the feed, schedules periodic background checks, and fires
  /// one silent check now so a newer build is surfaced on launch without the user
  /// asking. A no-op when the updater isn't enabled.
  Future<void> init() async {
    if (!isEnabled) return;
    await autoUpdater.setFeedURL(kAppcastFeedUrl);
    await autoUpdater.setScheduledCheckInterval(_dailySeconds);
    unawaited(checkInBackground());
  }

  /// Silent check — Sparkle surfaces its update prompt only when a newer build
  /// exists (no "you're up to date" dialog). Used on launch and whenever the
  /// account menu opens.
  Future<void> checkInBackground() async {
    if (!isEnabled) return;
    await autoUpdater.checkForUpdates(inBackground: true);
  }

  /// User-initiated check — shows Sparkle's UI even when already up to date, so
  /// an explicit "Check for updates" tap always gives feedback.
  Future<void> checkForUpdates() async {
    if (!isEnabled) return;
    await autoUpdater.checkForUpdates(inBackground: false);
  }
}

/// The app-update seam. Overridable in widget tests so pumping a screen that
/// shows the "Check for updates" action never reaches the native channel.
final appUpdaterServiceProvider =
    Provider<AppUpdaterService>((ref) => const AppUpdaterService());
