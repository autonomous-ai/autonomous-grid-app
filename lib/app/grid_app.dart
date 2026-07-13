import 'package:flutter/material.dart';

import '../features/app_update/presentation/update_toast_scope.dart';
import '../shared/layouts/tray_controller.dart';
import '../shared/theme/app_theme.dart';
import 'root_view.dart';
import 'window_lifecycle_scope.dart';

class GridApp extends StatelessWidget {
  const GridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grid',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      home: const WindowLifecycleScope(
        child: TrayScope(
          // Update-check feedback is mounted app-wide: the macOS "Check for
          // Updates…" menu item works on the login screen too.
          child: UpdateToastScope(child: RootView()),
        ),
      ),
    );
  }
}
