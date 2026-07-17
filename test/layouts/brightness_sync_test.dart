import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// Regression test for the sidebar not re-colouring when the theme is switched.
///
/// The color tokens read `AppTheme.brightness.value` at build time — a global the
/// element tree can't see. The chrome is mounted behind `const` boundaries
/// (`const AppSidebar()` under `const _MainShellBody()`), and a `const` child is
/// reference-identical across its parent's rebuild, so a top-down rebuild is
/// short-circuited before it reaches the sidebar. The reported symptom: switching
/// Dark→Light left the rail dark until an unrelated rebuild (clicking a row) hit.
///
/// The fix makes each token-reading chrome widget a *dependent* of the
/// [BrightnessScope] inherited notifier via [AppTheme.watch]; the framework then
/// rebuilds it directly when brightness flips, past any `const` ancestors. This
/// test mirrors that exact structure and asserts the leaf re-colours on its own,
/// with no interaction.
void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_brightness_sync_test');
    file = File('${tmp.path}/app/chat_prefs.json');
    AppTheme.brightness.value = Brightness.light;
  });
  tearDown(() async {
    AppTheme.brightness.value = Brightness.light;
    await tmp.delete(recursive: true);
  });

  testWidgets(
    'a const-mounted leaf re-colours the instant the theme flips, no interaction',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const _App()),
      );

      // Starts light.
      AppTheme.brightness.value = Brightness.light;
      final lightPanel = AppPalette.panelBg;
      expect(_panelColor(tester), lightPanel);

      // Flip the persisted choice to Dark — the same call the picker makes — and
      // pump WITHOUT tapping anything on the leaf. Only the notifier changed.
      container.read(chatPrefsProvider.notifier).setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();

      final darkPanel = AppPalette.panelBg;
      expect(darkPanel, isNot(equals(lightPanel)));
      expect(_panelColor(tester), darkPanel);

      // And back — Dark→Light, the direction from the bug report.
      container.read(chatPrefsProvider.notifier).setThemeMode(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(_panelColor(tester), lightPanel);
    },
  );
}

/// The colour the leaf panel is actually painting, read back off the element tree
/// — the observable that proves the const leaf rebuilt, not just the token value.
Color _panelColor(WidgetTester tester) {
  final box = tester.widget<ColoredBox>(find.byKey(const Key('sample-panel')));
  return box.color;
}

/// A miniature of the real app root: `MaterialApp` drives the theme; the home
/// syncs the notifier and wraps the subtree in [BrightnessScope]; the leaf is
/// reached only through a `const` boundary, exactly like `const AppSidebar()`.
class _App extends ConsumerWidget {
  const _App();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      themeMode: ref.watch(themeModeProvider),
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      home: const _BrightnessHost(),
    );
  }
}

/// Mirrors `_BrightnessSync`: sync the global from the resolved theme, then wrap
/// in [BrightnessScope] so token-reading descendants can subscribe.
class _BrightnessHost extends StatelessWidget {
  const _BrightnessHost();

  @override
  Widget build(BuildContext context) {
    AppTheme.brightness.value = Theme.of(context).brightness;
    return const BrightnessScope(child: _ConstBoundary());
  }
}

/// Stands in for `const _MainShellBody()` — a `const` widget between the scope
/// and the leaf. If the fix relied on a top-down rebuild it would die here.
class _ConstBoundary extends StatelessWidget {
  const _ConstBoundary();

  @override
  Widget build(BuildContext context) => const Scaffold(body: _SamplePanel());
}

/// Stands in for `const AppSidebar()`: subscribes via [AppTheme.watch] and paints
/// a token, so it must re-colour when brightness flips.
class _SamplePanel extends StatelessWidget {
  const _SamplePanel();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ColoredBox(
      key: const Key('sample-panel'),
      color: AppPalette.panelBg,
      child: const SizedBox(width: 100, height: 100),
    );
  }
}
