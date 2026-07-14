import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/app_update/presentation/update_toast_scope.dart';
import '../infrastructure/state/chat_prefs_store.dart';
import '../shared/layouts/tray_controller.dart';
import '../shared/theme/app_theme.dart';
import 'root_view.dart';
import 'window_lifecycle_scope.dart';

class GridApp extends ConsumerWidget {
  const GridApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Grid',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      // _BrightnessSync sits *below* MaterialApp so it reads the brightness
      // Material actually resolved (after ThemeMode.system is applied) and feeds
      // it to the color tokens, which resolve against AppTheme.brightness.
      home: const _BrightnessSync(
        child: WindowLifecycleScope(
          child: TrayScope(
            // Update-check feedback is mounted app-wide: the macOS "Check for
            // Updates…" menu item works on the login screen too.
            child: UpdateToastScope(child: RootView()),
          ),
        ),
      ),
    );
  }
}

/// Keeps [AppTheme.brightness] — the value every color token resolves against —
/// in step with the theme Material actually rendered. Under `ThemeMode.system`
/// that is the OS setting; under an explicit choice it is that choice.
///
/// The value is set *synchronously* during build, before the child paints, so a
/// token read this frame already sees the right brightness (no one-frame flash of
/// the wrong palette). This is safe because nothing rebuilds off the notifier —
/// the tokens read `.value` directly, and `MaterialApp` already rebuilds this
/// subtree whenever the resolved theme changes.
class _BrightnessSync extends StatelessWidget {
  const _BrightnessSync({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.brightness.value = Theme.of(context).brightness;
    return child;
  }
}
