import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/grid_app.dart';
import 'app/single_instance.dart';

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

  runApp(const ProviderScope(child: GridApp()));
}
