import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/appearance/presentation/appearance_view.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';
import 'package:grid_app/shared/layouts/widgets/section_view.dart';
import 'package:grid_app/features/appearance/presentation/theme_preview_tile.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The Appearance settings screen — the one place a theme is picked, now that
/// the account menu no longer carries a copy of the control. It owns no state of
/// its own, so what's worth pinning is that the section routes to it and that
/// picking a theme persists.
void main() {
  late Directory tmp;
  late File file;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_appearance_test');
    file = File('${tmp.path}/app/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  Widget host(Widget child) => ProviderScope(
    overrides: [
      chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets('the appearance section routes to the Appearance screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const SectionView(section: ShellSection.appearance)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceView), findsOneWidget);
  });

  testWidgets('picking a theme here persists it', (tester) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.dark);
  });

  testWidgets('names itself once — the page title, not also the control', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
  });

  // The label is a lot of people's aim — it's the part that names the thing —
  // so it has to be inside the hit box, not merely next to it. It wasn't at
  // first: the tap target stopped at the artwork and clicks on the word went
  // nowhere at all, silently.
  testWidgets('the whole tile is the target, artwork and label alike', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(
      ChatPrefsStore(file: file).load().themeMode,
      ThemeMode.dark,
      reason: 'tapping the label did nothing — the hit box excludes it',
    );

    // And the picture itself, for the same tile.
    await tester.tap(find.byType(ThemePreviewTile).first);
    await tester.pump();
    expect(ChatPrefsStore(file: file).load().themeMode, ThemeMode.system);
  });

  testWidgets('offers a preview of every theme', (tester) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();
    expect(
      find.byType(ThemePreviewTile),
      findsNWidgets(ThemeMode.values.length),
    );
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
  });

  // The point of the whole screen: the Dark tile has to show you *dark* while
  // you are sitting in light, or it isn't a preview. The tokens resolve against
  // one global brightness, so this only works because [AppTheme.as] swaps it for
  // the read — and this is what catches a tile that quietly went back to
  // painting whatever theme happens to be live.
  testWidgets('a preview paints its own palette, not the live one', (
    tester,
  ) async {
    AppTheme.brightness.value = Brightness.light;
    addTearDown(() => AppTheme.brightness.value = Brightness.light);

    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    Color canvasOf(String label) {
      final tile = find.ancestor(
        of: find.text(label),
        matching: find.byType(ThemePreviewTile),
      );
      return tester
          .widgetList<ColoredBox>(
            find.descendant(of: tile, matching: find.byType(ColoredBox)),
          )
          .first
          .color;
    }

    final liveWindow = AppPalette.windowBg;
    final darkWindow = AppTheme.as(Brightness.dark, () => AppPalette.windowBg);

    expect(canvasOf('Light'), liveWindow, reason: 'light tile = light palette');
    expect(
      canvasOf('Dark'),
      darkWindow,
      reason:
          'the Dark tile painted the live (light) palette — it is showing '
          'the current theme rather than the one it advertises',
    );
    expect(
      canvasOf('Dark').computeLuminance(),
      lessThan(canvasOf('Light').computeLuminance()),
    );

    // And the read must not leak: the app is still light after painting dark.
    expect(AppTheme.brightness.value, Brightness.light);
  });
}
