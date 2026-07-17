import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/layouts/widgets/theme_mode_picker.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_theme_picker_test');
    file = File('${tmp.path}/app/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  /// The picker only ever renders inside the account menu, so it's only ever
  /// meaningful at the menu's width — a picker measured on a full-width Scaffold
  /// would pass tests it fails in the one place it actually appears.
  Widget host() => ProviderScope(
    overrides: [
      chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
    ],
    child: const MaterialApp(
      home: Scaffold(
        // Column(min) rather than Align: Align fills the height it's given, so
        // the picker would measure the whole Scaffold and the height assertion
        // below would be meaningless.
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(width: 260, child: ThemeModePicker())],
        ),
      ),
    ),
  );

  testWidgets('offers Light, Dark and System', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
  });

  testWidgets('names itself, since nothing else in the menu does', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(find.text('Appearance'), findsOneWidget);
  });

  // "System" ellipsized to "Syst…" when the cells were laid out side by side:
  // ~70px a cell, and the glyph took the rest. A control that can't say the name
  // of its own option is broken, so this pins the label whole — a cell must fit
  // its word, not tidy it away.
  testWidgets('every option says its whole name at the menu width', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    for (final label in ['System', 'Light', 'Dark']) {
      final text = tester.widget<Text>(find.text(label));
      final painter = TextPainter(
        text: TextSpan(text: text.data, style: text.style),
        textDirection: TextDirection.ltr,
      )..layout();

      expect(
        painter.didExceedMaxLines,
        isFalse,
        reason: '"$label" does not fit its cell',
      );
      // The rendered box must be wide enough for the word as laid out — a
      // narrower one means the glyphs were clipped or ellipsized away.
      expect(
        tester.getSize(find.text(label)).width,
        greaterThanOrEqualTo(painter.width - 0.5),
        reason: '"$label" is being clipped — it renders narrower than the text '
            'it is meant to show',
      );
    }
  });

  testWidgets('tapping Dark persists the choice', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.dark);
  });

  // The account menu is positioned by summing the heights of the rows it will
  // show, and this picker is one of them (`_menuThemeHeight` in
  // sidebar_account.dart). That constant can't be derived at build time, so it
  // is measured here instead: if the picker grows past what the menu reserves,
  // the menu hangs in the air. It drifted once already — the constant said 107
  // while the widget measured 91 — which is what this exists to catch.
  testWidgets('stays within the height the account menu reserves for it', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // Keep in step with `_menuThemeHeight` in sidebar_account.dart.
    const reserved = 91.0;
    expect(
      tester.getSize(find.byType(ThemeModePicker)).height,
      lessThanOrEqualTo(reserved),
      reason: 'the picker outgrew the $reserved px the account menu reserves — '
          'update _menuThemeHeight in sidebar_account.dart to match',
    );
  });

  test('color tokens flip with AppTheme.brightness', () {
    AppTheme.brightness.value = Brightness.light;
    final lightBg = AppPalette.windowBg;
    final lightInk = AppPalette.textPrimary;

    AppTheme.brightness.value = Brightness.dark;
    final darkBg = AppPalette.windowBg;
    final darkInk = AppPalette.textPrimary;

    // The window is near-white in light and deep charcoal in dark; the ink
    // inverts to stay legible. If the resolver ever stopped switching, these
    // would be equal.
    expect(lightBg, isNot(equals(darkBg)));
    expect(lightInk, isNot(equals(darkInk)));
    expect(darkBg.computeLuminance(), lessThan(lightBg.computeLuminance()));
    expect(darkInk.computeLuminance(), greaterThan(lightInk.computeLuminance()));

    // Leave the global back at the shipped default so test order can't leak.
    AppTheme.brightness.value = Brightness.light;
  });
}
