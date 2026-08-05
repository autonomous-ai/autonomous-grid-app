import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/grid_app.dart';
import 'app/notification_scope.dart';
import 'app/single_instance.dart';
import 'core/grid_paths.dart';
import 'features/app_update/logic/app_updater_service.dart';
import 'features/connectors/presentation/connector_refresh_scope.dart';
import 'features/skills/presentation/grid_skills_scope.dart';
import 'infrastructure/logging/app_log.dart';
import 'infrastructure/logging/http_log.dart';
import 'infrastructure/logging/log_file.dart';
import 'infrastructure/platform/desktop_notifier.dart';

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

  final options = WindowOptions(
    // Wide enough to open with the project rail beside a chat — the conversation
    // column still clears its composer at this width (see ChatPane._inlineWidth).
    size: const Size(1280, 800),
    minimumSize: const Size(880, 560),
    title: 'Grid',
    center: true,
    // The frameless look is a macOS design choice, where the traffic-light
    // controls still render over a hidden title bar. Windows has no such overlay,
    // so a hidden bar leaves the window with no minimize/maximize/close buttons
    // (only Alt+F4 closes it). Keep the native caption bar on Windows/Linux.
    titleBarStyle: Platform.isMacOS
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  appLog.info('app', 'Window ready');

  // Configure macOS auto-update (Sparkle) before the UI shows: point it at the
  // feed and schedule its periodic checks. The *launch* check is fired later,
  // from the app shell — a first-run machine is busy installing an engine and
  // downloading a model, and an update prompt must not land on top of that.
  // A no-op off macOS or when no appcast feed is configured. `bindNativeMenu`
  // links the "Grid ▸ Check for Updates…" app-menu item to the same updater.
  final updater = AppUpdaterService(log: appLog);
  await updater.init();
  updater.bindNativeMenu();

  // Ask for notification permission once, here, rather than the first time a
  // task finishes: the prompt then arrives while the user is looking at the app,
  // not hours later on top of whatever they were doing. A machine that refuses
  // keeps the no-op notifier, so nothing later calls into a dead plugin.
  final notifier = SystemDesktopNotifier(log: appLog);
  final canNotify = await notifier.initialize();
  appLog.info(
    'notify',
    canNotify ? 'Notifications ready' : 'Notifications off',
  );

  appLog.info('app', 'Launching UI');
  runApp(
    ProviderScope(
      // Share the one file instance with every consumer (e.g. the command log
      // mirror) so the whole app writes to a single timeline. Hand the UI the same
      // updater instance that owns the Sparkle listener, so its check-outcome
      // toasts come from the checks the menu triggers.
      overrides: [
        appLogProvider.overrideWithValue(appLog),
        // Every HTTP call the app reports also lands in its own per-day file
        // (`app_https-YYYYMMDD.log`), written the moment the request is issued.
        httpLogProvider.overrideWithValue(buildFileHttpLog()),
        appUpdaterServiceProvider.overrideWithValue(updater),
        if (canNotify) desktopNotifierProvider.overrideWithValue(notifier),
      ],
      // Wraps the app rather than sitting inside it: connector tokens are
      // refreshed for the agent's sake, and the agent answers chats whether or
      // not the Connectors screen was ever opened.
      // Both wrap the app rather than sitting inside it, and for the same
      // reason: tokens and skills are the agent's, and the agent answers chats
      // whether or not the screen that manages them was ever opened.
      child: const ConnectorRefreshScope(
        child: GridSkillsScope(child: NotificationScope(child: GridApp())),
      ),
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
