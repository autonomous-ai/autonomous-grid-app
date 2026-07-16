import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/app_update/presentation/update_toast_scope.dart';
import '../infrastructure/state/chat_prefs_store.dart';
import '../shared/layouts/tray_controller.dart';
import '../shared/theme/app_theme.dart';
import '../shared/widgets/toast.dart';
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
            // Every transient notification in the app surfaces through this one
            // host, mounted above RootView so a toast is reachable from the
            // login screen and the main shell alike.
            child: ToastScope(
              // Update-check feedback is mounted app-wide: the macOS "Check for
              // Updates…" menu item works on the login screen too.
              child: UpdateToastScope(child: RootView()),
            ),
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
/// the wrong palette).
///
/// It reads `Theme.of(context)`, so the framework rebuilds it whenever the
/// resolved theme changes — including when the user picks Light/Dark from the
/// account menu, which flips `MaterialApp.themeMode`. Setting the notifier here
/// fires it, and [BrightnessScope] (wrapped around [child]) marks every widget
/// that called [AppTheme.watch] dirty — reaching them past the app's `const`
/// chrome, which a top-down rebuild can't (a `const` child is reference-identical
/// across its parent's rebuild, so Flutter skips it).
class _BrightnessSync extends StatelessWidget {
  const _BrightnessSync({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.brightness.value = Theme.of(context).brightness;
    return BrightnessScope(child: child);
  }
}
