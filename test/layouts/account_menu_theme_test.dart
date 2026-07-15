import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// Regression test for the account menu (a `MenuAnchor` popup) not re-colouring
/// when the theme is switched while it is open.
///
/// The menu renders in a detached `Overlay` entry, not under the sidebar widget
/// that opened it — so a top-down rebuild never reaches it, and its colour tokens
/// (read from a global the element tree can't track) stayed on the old palette.
/// The fix has the menu content depend on [BrightnessScope] via [AppTheme.watch];
/// this proves that dependency resolves *through the overlay* and re-colours the
/// open menu with no re-open.
void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_account_menu_theme_test');
    file = File('${tmp.path}/app/chat_prefs.json');
    AppTheme.brightness.value = Brightness.light;
  });
  tearDown(() async {
    AppTheme.brightness.value = Brightness.light;
    await tmp.delete(recursive: true);
  });

  testWidgets('an open menu-overlay re-colours when the theme flips', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _App()),
    );

    // Open the menu.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    AppTheme.brightness.value = Brightness.light;
    final lightFill = AppPalette.cardBg;
    expect(_menuFill(tester), lightFill);

    // Flip the theme *while the menu is open* — no re-open.
    container.read(chatPrefsProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();

    final darkFill = AppPalette.cardBg;
    expect(darkFill, isNot(equals(lightFill)));
    expect(_menuFill(tester), darkFill);
  });
}

/// The colour the menu panel is painting, read off the element tree.
Color _menuFill(WidgetTester tester) {
  final box = tester.widget<ColoredBox>(find.byKey(const Key('menu-panel')));
  return box.color;
}

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

/// Mirrors `_BrightnessSync`: sync the notifier and wrap in [BrightnessScope].
class _BrightnessHost extends StatelessWidget {
  const _BrightnessHost();

  @override
  Widget build(BuildContext context) {
    AppTheme.brightness.value = Theme.of(context).brightness;
    return const BrightnessScope(child: _MenuHost());
  }
}

/// A `MenuAnchor` whose content — like the real account menu — lives in a
/// detached overlay and subscribes to the brightness via [AppTheme.watch].
class _MenuHost extends StatelessWidget {
  const _MenuHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: MenuAnchor(
          menuChildren: const [_MenuPanel()],
          builder: (context, controller, _) => TextButton(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ColoredBox(
      key: const Key('menu-panel'),
      color: AppPalette.cardBg,
      child: const SizedBox(width: 180, height: 120),
    );
  }
}
