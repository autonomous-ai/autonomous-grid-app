import 'package:flutter/material.dart';

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
      home: const WindowLifecycleScope(child: TrayScope(child: RootView())),
    );
  }
}
