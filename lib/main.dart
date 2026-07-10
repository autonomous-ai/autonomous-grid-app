import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/grid_app.dart';
import 'app/single_instance.dart';
import 'core/grid_paths.dart';
import 'features/app_update/logic/app_updater_service.dart';
import 'infrastructure/logging/app_log.dart';
import 'infrastructure/logging/log_file.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Wire the durable app-log first so every later step — including a crash
  // during startup — lands in `~/.grid/logs/app-YYYYMMDD.log`.
  final appLog = FileAppLog(
    DailyLogFile(GridPaths.logsDir, GridPaths.appLogBase),
  );
  _installErrorHandlers(appLog);
  appLog.info('app', 'Grid starting');

  // Boot the libmpv backend powering inline chat video/audio playback.
  MediaKit.ensureInitialized();

  // Quit instantly if another instance already holds the lock. `flutter run` on
  // macOS exec's the binary then calls `open`, which makes LaunchServices spawn
  // duplicate instances; without this each one shows a window and steals focus.
  if (!await acquireSingleInstanceLock()) {
    appLog.info('app', 'Another instance already running — exiting');
    exit(0);
  }

  await windowManager.ensureInitialized();

  // Intercept the close button so a running engine can be stopped first (see
  // WindowLifecycleScope.onWindowClose). Without this the window closes
  // immediately and the detached engine is left serving on the relay.
  await windowManager.setPreventClose(true);

  const options = WindowOptions(
    size: Size(1100, 720),
    minimumSize: Size(880, 560),
    title: 'Grid',
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  appLog.info('app', 'Window ready');

  // Configure macOS auto-update (Sparkle) before the UI shows: silent, scheduled
  // background checks that surface a prompt only when a newer signed build is
  // published. A no-op off macOS or when no appcast feed is configured.
  // `bindNativeMenu` links the "Grid ▸ Check for Updates…" app-menu item to the
  // same updater.
  final updater = AppUpdaterService(log: appLog);
  await updater.init();
  updater.bindNativeMenu();

  appLog.info('app', 'Launching UI');
  runApp(
    ProviderScope(
      // Share the one file instance with every consumer (e.g. the command log
      // mirror) so the whole app writes to a single timeline. Hand the UI the same
      // updater instance that owns the Sparkle listener, so its check-outcome
      // toasts come from the checks the menu triggers.
      overrides: [
        appLogProvider.overrideWithValue(appLog),
        appUpdaterServiceProvider.overrideWithValue(updater),
      ],
      child: const GridApp(),
    ),
  );
}

/// Route Flutter framework errors and otherwise-uncaught async errors into
/// [appLog] so a shipped build leaves a stack trace on disk instead of only in
/// a console no one is watching. The framework's default console presentation is
/// preserved for local development.
void _installErrorHandlers(AppLog appLog) {
  final priorOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    priorOnError?.call(details);
    appLog.failure(
      'flutter',
      details.exceptionAsString(),
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    appLog.failure('app', 'Uncaught error', error: error, stackTrace: stack);
    return true;
  };
}
