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

  /// Sparkle's minimum check interval is 3600s; once a day is plenty for a
  /// desktop app that also checks shortly after launch.
  static const int _dailySeconds = 86400;

  /// True when a feed is configured on a platform the updater supports. Gates
  /// both the background schedule and the manual "Check for updates" action.
  bool get isEnabled => Platform.isMacOS && kAppcastFeedUrl.isNotEmpty;

  /// Points Sparkle at the feed and enables silent, scheduled background checks.
  /// Sparkle surfaces its native prompt only when a newer build is actually
  /// found, so a routine check never nags an up-to-date user. Safe to call on
  /// every launch; a no-op when the updater isn't enabled.
  Future<void> init() async {
    if (!isEnabled) return;
    await autoUpdater.setFeedURL(kAppcastFeedUrl);
    await autoUpdater.setScheduledCheckInterval(_dailySeconds);
  }

  /// User-initiated check. Unlike the background schedule this shows Sparkle's UI
  /// even when already up to date, so it's wired to an explicit button only.
  Future<void> checkForUpdates() async {
    if (!isEnabled) return;
    await autoUpdater.checkForUpdates();
  }
}

/// The app-update seam. Overridable in widget tests so pumping a screen that
/// shows the "Check for updates" action never reaches the native channel.
final appUpdaterServiceProvider =
    Provider<AppUpdaterService>((ref) => const AppUpdaterService());
