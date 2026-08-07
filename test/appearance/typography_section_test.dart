import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:grid_app/features/appearance/presentation/typography_section.dart';
import 'package:grid_app/shared/markdown/markdown_code_block.dart';
import 'package:grid_app/infrastructure/platform/system_fonts.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The Typography settings, from the user's side: type a size, get that size
/// stored; pick a face, get that face stored.
///
/// Deliberately not testing what the type *looks* like — the headless font
/// manager resolves every family to one test face, so a rendering assertion
/// here would pass whether or not the font ever changed. That question belongs
/// to a screenshot of the running app.
void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    AppFont.reset();
    tmp = await Directory.systemTemp.createTemp('grid_typography_test');
    file = File('${tmp.path}/app/chat_prefs.json');
  });
  tearDown(() async {
    AppFont.reset();
    await tmp.delete(recursive: true);
  });

  ChatPrefs stored() => ChatPrefsStore(file: file).load();

  /// [installed] stands in for a Mac's UI fonts; [monospaced] for the
  /// fixed-pitch subset the code picker is allowed to offer. They are separate
  /// because the split is the point — see InstalledFonts.
  Widget host({
    List<String> installed = const [],
    List<String> monospaced = const [],
  }) => ProviderScope(
    overrides: [
      chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
      // The real provider goes out to a platform channel no test is listening
      // on; this stands in for a Mac with a known set of fonts.
      installedFontFamiliesProvider.overrideWith(
        (ref) async => InstalledFonts(all: installed, monospaced: monospaced),
      ),
    ],
    child: MaterialApp(
      theme: buildAppTheme(),
      home: const BrightnessScope(
        child: Scaffold(
          body: SingleChildScrollView(child: TypographySection()),
        ),
      ),
    ),
  );

  Future<void> typeSize(WidgetTester tester, Key field, String text) async {
    await tester.enterText(find.byKey(field), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  group('the size fields', () {
    testWidgets('a typed size is stored on Enter', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await typeSize(tester, const Key('ui-font-size'), '17');
      expect(stored().uiFontSize, 17);

      await typeSize(tester, const Key('code-font-size'), '11');
      expect(stored().codeFontSize, 11);
    });

    // A size field a user can type anything into has to be bounded somewhere,
    // and rejecting the input outright would leave them with a field that
    // silently does nothing. Snapping says what happened.
    testWidgets('an out-of-range size snaps to the nearest bound', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await typeSize(tester, const Key('ui-font-size'), '400');
      expect(stored().uiFontSize, ChatPrefs.maxUiFontSize);

      await typeSize(tester, const Key('ui-font-size'), '2');
      expect(stored().uiFontSize, ChatPrefs.minUiFontSize);
    });

    // The field must never disagree with the app: if 400 became 19, the box has
    // to say 19, or the next Enter re-submits a number that isn't the setting.
    testWidgets('the field is rewritten to what was actually stored', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await typeSize(tester, const Key('ui-font-size'), '400');
      final field = tester.widget<TextField>(
        find.byKey(const Key('ui-font-size')),
      );
      expect(field.controller!.text, '19');
    });

    testWidgets('unparseable input reverts rather than resetting', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await typeSize(tester, const Key('ui-font-size'), '16');
      expect(stored().uiFontSize, 16);

      // A stray "." is what's left mid-edit; it must not throw away the 16.
      await typeSize(tester, const Key('ui-font-size'), '.');
      expect(stored().uiFontSize, 16);
      final field = tester.widget<TextField>(
        find.byKey(const Key('ui-font-size')),
      );
      expect(field.controller!.text, '16');
    });

    testWidgets('a whole number renders without a trailing .0', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final ui = tester.widget<TextField>(
        find.byKey(const Key('ui-font-size')),
      );
      final code = tester.widget<TextField>(
        find.byKey(const Key('code-font-size')),
      );
      expect(ui.controller!.text, '14');
      // …but a half step survives, since the code default is 12.5.
      expect(code.controller!.text, '12.5');
    });
  });

  /// Opens one of the two pickers by identity, not by the word showing in it —
  /// both read "System" at rest, so a text finder can't tell them apart.
  Future<void> openPicker(WidgetTester tester, String key) async {
    await tester.tap(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(InkWell))
          .first,
    );
    await tester.pumpAndSettle();
  }

  group('the font pickers', () {
    testWidgets('picking a family stores it', (tester) async {
      await tester.pumpWidget(host(installed: const ['Menlo', 'Inter']));
      await tester.pumpAndSettle();

      await openPicker(tester, 'ui-font-picker');
      await tester.tap(find.text('Inter').last);
      await tester.pumpAndSettle();

      expect(stored().uiFontFamily, 'Inter');
    });

    // "System" is a real choice, not the absence of one — and it has to be able
    // to undo a pick. This is the copyWith clear-flag path, from the UI side.
    testWidgets('picking System puts it back to the default font', (
      tester,
    ) async {
      ChatPrefsStore(file: file).save(const ChatPrefs(uiFontFamily: 'Inter'));
      await tester.pumpWidget(host(installed: const ['Inter']));
      await tester.pumpAndSettle();

      await openPicker(tester, 'ui-font-picker');
      await tester.tap(find.text('System').last);
      await tester.pumpAndSettle();

      expect(stored().uiFontFamily, isNull);
    });

    testWidgets('only installed families are offered', (tester) async {
      await tester.pumpWidget(host(installed: const ['Menlo']));
      await tester.pumpAndSettle();

      await openPicker(tester, 'ui-font-picker');

      expect(
        find.text('Inter'),
        findsNothing,
        reason: 'a face this Mac lacks would silently fall back if picked',
      );
      expect(find.text('Menlo'), findsWidgets);
    });

    // The code picker takes the fixed-pitch list, not the full one. Offering
    // every installed family put "Apple Symbols" in it — a symbol face, which
    // renders source as pictograms if picked.
    testWidgets('the code picker offers only fixed-pitch families', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          installed: const ['Apple Symbols', 'Helvetica Neue', 'Menlo'],
          monospaced: const ['Menlo'],
        ),
      );
      await tester.pumpAndSettle();

      await openPicker(tester, 'code-font-picker');

      expect(find.text('Menlo'), findsWidgets);
      expect(
        find.text('Apple Symbols'),
        findsNothing,
        reason: 'a symbol font is not a code font',
      );
      expect(find.text('Helvetica Neue'), findsNothing);
    });

    testWidgets('the UI picker still offers proportional families', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          installed: const ['Helvetica Neue', 'Menlo'],
          monospaced: const ['Menlo'],
        ),
      );
      await tester.pumpAndSettle();

      await openPicker(tester, 'ui-font-picker');
      expect(find.text('Helvetica Neue'), findsWidgets);
    });

    // Prefs travel between Macs. A family that resolved on one and not on
    // another must stay visible and be named as missing — otherwise the picker
    // shows a font whose text is being drawn in something else entirely.
    testWidgets('a chosen family that is missing is kept, and said so', (
      tester,
    ) async {
      ChatPrefsStore(
        file: file,
      ).save(const ChatPrefs(uiFontFamily: 'Berkeley Mono'));
      await tester.pumpWidget(host(installed: const ['Menlo']));
      await tester.pumpAndSettle();

      expect(find.text('Berkeley Mono'), findsOneWidget);
      await tester.tap(find.text('Berkeley Mono'));
      await tester.pumpAndSettle();
      // Once, in the closed field's pill — and again in the open menu row it
      // belongs to. Both are the point: the warning has to be visible while
      // picking, not only after.
      expect(find.text('Not installed on this Mac'), findsWidgets);
    });
  });

  group('the preview', () {
    // The preview used to be a hand-drawn lookalike: a plain box of mono text
    // with no header, no copy action and no syntax colour. That both under-sold
    // the settings and could drift from the thing it claims to preview. Using
    // the transcript's own widget is what makes "preview" true, so it is worth
    // a test — a future tidy-up that inlines a simpler box would otherwise pass
    // silently.
    testWidgets('renders the chat\'s real code block, not a lookalike', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    });

    testWidgets('shows the block complete: language, copy action and code', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      // The header names the language, exactly as a fenced block in a reply
      // does.
      expect(find.text('python'), findsOneWidget);
      // `closed: true` is what gates the copy action on. A preview stuck in the
      // streaming state would show "writing…" instead, and the setting would be
      // previewed by a half-rendered block.
      expect(find.text('writing…'), findsNothing);
      expect(find.byIcon(LucideIcons.copy300), findsOneWidget);
    });

    // The specimen earns its place by exercising the characters a code face is
    // actually judged on. A sample without them previews the size but not the
    // face, which is half the setting.
    testWidgets('the sample carries the glyphs a code face is judged on', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      final code = tester
          .widget<MarkdownCodeBlock>(find.byType(MarkdownCodeBlock))
          .code;

      expect(code, contains('0O'), reason: 'zero against capital O');
      expect(
        code,
        contains('1lI'),
        reason: 'one against ell against capital i',
      );
      for (final glyphs in ['{', '}', '(', ')', '[', ']', '->', '"']) {
        expect(code, contains(glyphs), reason: 'missing $glyphs');
      }
    });
  });

  group('buildFontOptions', () {
    test('curated names come first, then everything else installed', () {
      final options = buildFontOptions(
        curated: const [
          FontChoice(label: 'System', family: null),
          FontChoice(label: 'Menlo', family: 'Menlo'),
        ],
        installed: const ['Arial', 'Menlo', 'Zapfino'],
      );

      expect(options.map((o) => o.label).toList(), [
        'System',
        'Menlo',
        'Arial',
        'Zapfino',
      ]);
    });

    test('a curated face is never listed twice', () {
      final options = buildFontOptions(
        curated: const [FontChoice(label: 'Menlo', family: 'Menlo')],
        installed: const ['Menlo'],
      );
      expect(options.where((o) => o.family == 'Menlo').length, 1);
    });

    test('a curated face this Mac lacks is marked, not dropped', () {
      final options = buildFontOptions(
        curated: const [FontChoice(label: 'Inter', family: 'Inter')],
        installed: const ['Menlo'],
      );
      expect(
        options.firstWhere((o) => o.family == 'Inter').detail,
        'Not installed',
      );
    });

    // With no platform answer at all — a failed channel, or a widget test —
    // the curated list still has to be usable rather than empty.
    test('an empty installed list still yields the curated names', () {
      final options = buildFontOptions(
        curated: kCuratedCodeFonts,
        installed: const [],
      );
      expect(options.length, kCuratedCodeFonts.length);
      expect(options.first.family, isNull, reason: 'System is always offered');
    });
  });

  group('isFamilyInstalled', () {
    test('the system font is always considered present', () {
      expect(isFamilyInstalled(null, const []), isTrue);
    });

    test('a named family is only present when the list says so', () {
      expect(isFamilyInstalled('Menlo', const ['Menlo']), isTrue);
      expect(isFamilyInstalled('Menlo', const ['Arial']), isFalse);
    });
  });
}
