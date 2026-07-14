import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/shared/layouts/settings_pane.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';
import 'package:grid_app/shared/layouts/widgets/sidebar_item.dart';

/// An account with no grids — enough for the settings frame, and it keeps the
/// test off the real `~/.grid`.
class _FakeStore extends GridHomeStore {
  const _FakeStore();

  @override
  CredentialsFile readCredentials() => const CredentialsFile(networks: []);

  @override
  String? readActiveRemoteGrid() => null;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_settings_pane_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  /// Settings on its lightest screen — the guide with no grid selected — so the
  /// test is about the settings frame, not what's inside it.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required Size at,
  }) async {
    await tester.binding.setSurfaceSize(at);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gridHomeStoreProvider.overrideWithValue(const _FakeStore()),
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SettingsPane(section: ShellSection.guide)),
        ),
      ),
    );
    await tester.pump();

    return ProviderScope.containerOf(tester.element(find.byType(SettingsPane)));
  }

  Finder navRow(String label) => find.widgetWithText(SidebarItem, label);

  testWidgets('every setup screen is behind the one door, and the open one is '
      'marked — no hunting through a menu', (tester) async {
    await pump(tester, at: const Size(1200, 800));

    for (final section in kSettingsSections) {
      expect(navRow(section.label), findsOneWidget);
    }
    expect(
      tester.widget<SidebarItem>(navRow('How to use')).selected,
      isTrue,
      reason: 'the screen you are on is the one highlighted',
    );
    expect(tester.widget<SidebarItem>(navRow('Grids')).selected, isFalse);
  });

  testWidgets('picking one opens it', (tester) async {
    final container = await pump(tester, at: const Size(1200, 800));

    await tester.tap(navRow('Telegram'));
    await tester.pump();

    expect(container.read(shellSectionProvider), ShellSection.telegram);
  });

  testWidgets('Back to app is the way out — Settings takes the window, so '
      'without it there would be none', (tester) async {
    final container = await pump(tester, at: const Size(1200, 800));

    await tester.tap(find.text('Back to app'));
    // The header doubles as the window's drag handle, whose double-tap
    // recognizer leaves a timer behind — let it expire.
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(shellSectionProvider), ShellSection.chat);
  });

  testWidgets('a narrow window keeps the screen and drops the labels — the nav '
      'must not squeeze the thing it opens', (tester) async {
    await pump(tester, at: const Size(880, 700));

    expect(navRow('Grids'), findsNothing);
    // Still reachable, and still named — just in the tooltip.
    for (final section in kSettingsSections) {
      expect(find.byTooltip(section.label), findsOneWidget);
    }
    expect(tester.takeException(), isNull, reason: 'nothing overflowed');
  });

  test('Settings opens on the screen it lists first, not on nothing', () {
    expect(kDefaultSettingsSection, kSettingsSections.first);
    expect(ShellSection.grids.isSettings, isTrue);
    expect(ShellSection.chat.isSettings, isFalse);
  });
}
