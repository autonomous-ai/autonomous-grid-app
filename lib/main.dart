import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/grid_app.dart';
import 'app/notification_scope.dart';
import 'app/panel_scope.dart';
import 'app/single_instance.dart';
import 'core/grid_paths.dart';
import 'features/app_update/logic/app_updater_service.dart';
import 'features/connectors/presentation/connector_refresh_scope.dart';
import 'features/skills/presentation/grid_skills_scope.dart';
import 'infrastructure/logging/app_log.dart';
import 'infrastructure/logging/error_burst_filter.dart';
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

  // Quit if another instance already holds the lock. `flutter run` on macOS
  // exec's the binary then calls `open`, which makes LaunchServices spawn
  // duplicate instances; without this each one shows a window and steals focus.
  // The claim waits out a Sparkle relaunch rather than resolving on the first
  // refusal — see acquireSingleInstanceLock.
  final lock = await acquireSingleInstanceLock();
  if (lock == InstanceLock.deferred) {
    appLog.info('app', 'Another instance already running — exiting');
    exit(0);
  }
  // Worth a line of its own: this launch decided the previous holder was dead.
  // If that call was wrong the user is now looking at two Grid windows, and
  // this is the only record that says which of the two paths was taken.
  if (lock == InstanceLock.reclaimed) {
    appLog.info('app', 'Took over the instance lock — no live Grid answered');
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

  // Built here so the whole app shares one notifier, but *not* asked for
  // permission here: `ensurePermission` doesn't return until the user answers
  // the OS dialog, and the window is already on screen (above) with no frame to
  // paint until `runApp` — awaiting the answer showed a black, unclosable window
  // for as long as the prompt stood. The shell asks instead, after the first
  // frame (HomeShell.initState), like the launch update check.
  final notifier = SystemDesktopNotifier(log: appLog);

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
        // Unconditional: whether this machine allows notifications is the
        // notifier's own business now, and `show` is a no-op until it knows.
        desktopNotifierProvider.overrideWithValue(notifier),
      ],
      // Wraps the app rather than sitting inside it: connector tokens are
      // refreshed for the agent's sake, and the agent answers chats whether or
      // not the Connectors screen was ever opened.
      // Both wrap the app rather than sitting inside it, and for the same
      // reason: tokens and skills are the agent's, and the agent answers chats
      // whether or not the screen that manages them was ever opened.
      // The panel is the same shape of thing: it is plugged into the desk, and
      // it answers whatever the window happens to be showing.
      child: const ConnectorRefreshScope(
        child: GridSkillsScope(
          child: PanelScope(child: NotificationScope(child: GridApp())),
        ),
      ),
    ),
  );
}

/// Route Flutter framework errors and otherwise-uncaught async errors into
/// [appLog] so a shipped build leaves a stack trace on disk instead of only in
/// a console no one is watching. The framework's default console presentation is
/// preserved for local development.
///
/// Repeats are collapsed by [ErrorBurstFilter]: an error thrown from a frame is
/// thrown again by every frame after it, and writing each copy — an fsync per
/// stack trace, on the UI isolate — is what turns a broken frame into a frozen
/// app rather than a janky one.
void _installErrorHandlers(AppLog appLog) {
  final bursts = ErrorBurstFilter();
  final priorOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    priorOnError?.call(details);
    final line = bursts.admit(details.exceptionAsString());
    if (line == null) return;
    appLog.failure(
      'flutter',
      line,
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    // Keyed on the error itself, not on the sentence below it: every uncaught
    // error shares that sentence, and one repeating failure must not silence
    // the next unrelated one.
    final line = bursts.admit('$error');
    if (line != null) {
      appLog.failure('app', 'Uncaught error: $line', stackTrace: stack);
    }
    return true;
  };
}
