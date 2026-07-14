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

  Widget host() => ProviderScope(
    overrides: [
      chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ThemeModePicker()),
    ),
  );

  testWidgets('offers Light, Dark and System', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
  });

  testWidgets('tapping Dark persists the choice', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.dark);
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
