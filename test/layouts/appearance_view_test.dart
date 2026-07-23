import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/appearance/presentation/appearance_view.dart';
import 'package:grid_app/features/network/presentation/grid_overview_widgets.dart';
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

  /// The screen as the app really mounts it.
  ///
  /// `BrightnessScope` is not optional scaffolding: it is the InheritedNotifier
  /// `AppTheme.watch` registers against, so without it every watch call in the
  /// tree is a no-op and a theme-following test would pass or fail for reasons
  /// that have nothing to do with the widget under test. `grid_app.dart` mounts
  /// it just below MaterialApp, which is what this mirrors.
  Widget host(Widget child) => ProviderScope(
    overrides: [
      chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
    ],
    child: MaterialApp(
      theme: buildAppTheme(),
      home: BrightnessScope(child: Scaffold(body: child)),
    ),
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

  // The page scrolls — the type settings pushed it past a screenful — so every
  // line at the top of it costs the user a scroll before they can read the
  // heading. An empty Text still occupies its line box, so a heading with
  // nothing to add was spending one anyway.
  testWidgets('a heading with nothing to add spends no line on it', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    final themeHeading = find.ancestor(
      of: find.text('Theme'),
      matching: find.byType(SectionHeading),
    );
    expect(themeHeading, findsOneWidget);

    // The heading box is exactly its title, with no blank second line under it.
    final headingHeight = tester.getRect(themeHeading).height;
    final titleHeight = tester.getRect(find.text('Theme')).height;
    expect(
      headingHeight,
      closeTo(titleHeight, 0.5),
      reason: 'an empty subtitle is still taking up a line',
    );
  });

  // …and the one that does have something to say still says it.
  testWidgets('a heading with a subtitle still renders it', (tester) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    final typography = find.ancestor(
      of: find.text('Typography'),
      matching: find.byType(SectionHeading),
    );
    expect(
      tester.getRect(typography).height,
      greaterThan(tester.getRect(find.text('Typography')).height),
    );
  });

  // Both headings have to *follow* the theme, not merely be built in one.
  //
  // This is the AppTheme.watch trap, and Appearance is where it bites hardest:
  // the screen is static, so nothing else ever rebuilds a heading, and one that
  // doesn't watch keeps whichever palette it first built with. Grids hid the
  // same bug because its Riverpod data churn rebuilt everything anyway.
  testWidgets('the section headings repaint when the theme flips', (
    tester,
  ) async {
    AppTheme.brightness.value = Brightness.light;
    addTearDown(() => AppTheme.brightness.value = Brightness.light);

    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();

    Color inkOf(String title) =>
        tester.widget<Text>(find.text(title)).style!.color!;

    final lightTheme = inkOf('Theme');
    final lightTypography = inkOf('Typography');

    AppTheme.brightness.value = Brightness.dark;
    await tester.pumpAndSettle();

    expect(
      inkOf('Theme'),
      isNot(lightTheme),
      reason: '"Theme" is stuck on the palette it first built with',
    );
    expect(
      inkOf('Typography'),
      isNot(lightTypography),
      reason: '"Typography" is stuck on the palette it first built with',
    );
    // …and it moved the right way: dark ink on light, light ink on dark.
    expect(
      inkOf('Typography').computeLuminance(),
      greaterThan(lightTypography.computeLuminance()),
    );
  });

  testWidgets('offers a preview of every theme', (tester) async {
    await tester.pumpWidget(host(const AppearanceView()));
    await tester.pumpAndSettle();
    expect(
      find.byType(ThemePreviewTile),
      findsNWidgets(ThemeMode.values.length),
    );
    // Scoped to the tiles rather than the whole screen: "System" is also the
    // font pickers' word for the default face, so a bare `find.text('System')`
    // matches three things on this screen and none of the extra two are a theme.
    Finder tileLabel(String label) => find.descendant(
      of: find.byType(ThemePreviewTile),
      matching: find.text(label),
    );
    expect(tileLabel('System'), findsOneWidget);
    expect(tileLabel('Light'), findsOneWidget);
    expect(tileLabel('Dark'), findsOneWidget);
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
