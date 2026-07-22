import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/features/projects/presentation/project_menu.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The menu's four actions, driven through the rows a user actually clicks — the
/// menu was restyled, and these pin the behaviour behind it so a later change to
/// how it *looks* can't quietly change what it *does*.
///
/// The menu is also positioned by summing its row heights, so a row that quietly
/// grows leaves it floating clear of the "…" it hangs off; one test measures the
/// drawn result rather than trusting the arithmetic. And an open menu lives in a
/// detached overlay a top-down theme flip can't reach, so another pins that too.

void main() {
  late Directory tmp;
  late File file;
  late Directory projectDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_project_menu_test');
    file = File('${tmp.path}/projects.json');
    // A real folder on disk, so `project.exists` is true and the reveal row shows.
    projectDir = await Directory('${tmp.path}/grid').create();
  });
  tearDown(() => tmp.delete(recursive: true));

  /// Seeds one project and mounts its menu button, returning the container so a
  /// test can read back what the action did.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool pinned = false,
    bool exists = true,
  }) async {
    final project = Project(
      id: 'p1',
      name: 'grid',
      path: exists ? projectDir.path : '${tmp.path}/gone',
      pinned: pinned,
    );
    final container = ProviderContainer(
      overrides: [
        projectsStoreProvider.overrideWithValue(ProjectsStore(file: file)),
      ],
    );
    addTearDown(container.dispose);
    // Seed through the controller so the state and the file agree.
    container.read(projectsProvider.notifier).add(project.path);
    final seeded = container.read(projectsProvider).single;
    if (pinned) {
      container.read(projectsProvider.notifier).setPinned(seeded.id, true);
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: BrightnessScope(
          child: MaterialApp(
            home: Scaffold(
              // Centred so there is room on every side: against an edge the menu
              // gets clamped, which would mask a height mismatch.
              body: Center(
                child: ProjectMenuButton(
                  project: container.read(projectsProvider).single,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(ProjectMenuButton));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu offers its actions, destructive one last', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);

    expect(find.text('Pin project'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Rename project'), findsOneWidget);
    expect(find.text('Remove from Grid'), findsOneWidget);
  });

  testWidgets('a folder that is gone offers nothing to reveal', (tester) async {
    await pump(tester, exists: false);
    await open(tester);

    expect(find.text('Show in Finder'), findsNothing);
    // The rest still work — a missing folder can still be renamed or removed.
    expect(find.text('Rename project'), findsOneWidget);
    expect(find.text('Remove from Grid'), findsOneWidget);
  });

  testWidgets('Pin project pins it, and the menu then offers to unpin', (
    tester,
  ) async {
    final c = await pump(tester);
    await open(tester);
    await tester.tap(find.text('Pin project'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider).single.pinned, isTrue);
  });

  testWidgets('Unpin project unpins it', (tester) async {
    final c = await pump(tester, pinned: true);
    await open(tester);
    expect(find.text('Unpin project'), findsOneWidget);
    await tester.tap(find.text('Unpin project'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider).single.pinned, isFalse);
  });

  testWidgets('Rename project renames it once confirmed', (tester) async {
    final c = await pump(tester);
    await open(tester);
    await tester.tap(find.text('Rename project'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Renamed');
    // "Rename" disables itself on a blank or unchanged name, so the tap has to
    // land on a rebuilt button — without this frame it hits the disabled one.
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider).single.name, 'Renamed');
  });

  testWidgets('Rename cancelled leaves the name alone', (tester) async {
    final c = await pump(tester);
    await open(tester);
    await tester.tap(find.text('Rename project'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Nope');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider).single.name, 'grid');
  });

  testWidgets('Remove from Grid asks first, and removes once confirmed', (
    tester,
  ) async {
    final c = await pump(tester);
    await open(tester);
    await tester.tap(find.text('Remove from Grid'));
    await tester.pumpAndSettle();

    // It asks before it does anything destructive.
    expect(find.text('Remove "grid"?'), findsOneWidget);
    expect(c.read(projectsProvider), hasLength(1));

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider), isEmpty);
    // The folder itself is the user's, not the app's — it stays put.
    expect(projectDir.existsSync(), isTrue);
  });

  testWidgets('Remove cancelled keeps the project', (tester) async {
    final c = await pump(tester);
    await open(tester);
    await tester.tap(find.text('Remove from Grid'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(c.read(projectsProvider), hasLength(1));
  });

  testWidgets('the menu hangs off the button, not near it', (tester) async {
    await pump(tester);
    final anchor = tester.getRect(find.byType(ProjectMenuButton));
    await open(tester);

    // Every row sits below the button and within a menu's reach of it — the
    // check that fails if the summed height drifts from the drawn height.
    final top = tester.getRect(find.text('Pin project')).top;
    final bottom = tester.getRect(find.text('Remove from Grid')).bottom;
    expect(top, greaterThan(anchor.bottom));
    expect(bottom - anchor.bottom, lessThan(180));
  });

  testWidgets('rows measure the height the menu is positioned from', (
    tester,
  ) async {
    // The menu places itself by summing a _rowHeight constant, so a row that
    // draws taller than that constant floats the whole panel off its button.
    // The two are only kept honest by measuring, never by reading the code:
    // pitch here must equal _rowHeight (34).
    await pump(tester);
    await open(tester);

    final pin = tester.getRect(find.text('Pin project')).top;
    final finder = tester.getRect(find.text('Show in Finder')).top;
    final rename = tester.getRect(find.text('Rename project')).top;

    expect(finder - pin, 34.0, reason: 'row pitch drifted from _rowHeight');
    expect(rename - finder, 34.0);
  });

  testWidgets('an open menu re-colours when the theme flips', (tester) async {
    addTearDown(() => AppTheme.brightness.value = Brightness.light);
    AppTheme.brightness.value = Brightness.light;
    await pump(tester);
    await open(tester);

    Color labelColor() =>
        tester.widget<Text>(find.text('Rename project')).style!.color!;
    final light = labelColor();

    AppTheme.brightness.value = Brightness.dark;
    await tester.pumpAndSettle();

    expect(labelColor(), isNot(light));
  });
}
