import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/grid_app.dart';
import 'app/single_instance.dart';
import 'features/app_update/logic/app_updater_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Boot the libmpv backend powering inline chat video/audio playback.
  MediaKit.ensureInitialized();

  // Quit instantly if another instance already holds the lock. `flutter run` on
  // macOS exec's the binary then calls `open`, which makes LaunchServices spawn
  // duplicate instances; without this each one shows a window and steals focus.
  if (!await acquireSingleInstanceLock()) {
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

  // Configure macOS auto-update (Sparkle) before the UI shows: silent, scheduled
  // background checks that surface a prompt only when a newer signed build is
  // published. A no-op off macOS or when no appcast feed is configured.
  await const AppUpdaterService().init();

  runApp(const ProviderScope(child: GridApp()));
}
