import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

/// The type settings on disk.
///
/// Everything here is about a file the app has to survive reading: prefs are
/// hand-editable JSON in `~/.grid/app/`, they get synced between Macs, and they
/// outlive the version of the app that wrote them. A size that arrives broken
/// must not be able to render the app unusable — including too broken to reach
/// the setting that would fix it.
void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_font_prefs_test');
    file = File('${tmp.path}/app/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ChatPrefs loadRaw(Map<String, Object?> json) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(json));
    return ChatPrefsStore(file: file).load();
  }

  group('defaults', () {
    test('an app that has never been configured is set in the system font', () {
      const prefs = ChatPrefs.empty;
      expect(prefs.uiFontFamily, isNull);
      expect(prefs.codeFontFamily, isNull);
      expect(prefs.uiFontSize, ChatPrefs.defaultUiFontSize);
      expect(prefs.codeFontSize, ChatPrefs.defaultCodeFontSize);
    });

    // The file predates this feature on every existing install, so the four
    // keys are simply absent there. That has to read as "shipped defaults",
    // not as zero — a 0px UI is an app with no text in it.
    test('a prefs file written before this feature reads as the defaults', () {
      final prefs = loadRaw({'themeMode': 'dark', 'chatAgent': 'codex'});
      expect(prefs.themeMode.name, 'dark');
      expect(prefs.uiFontSize, ChatPrefs.defaultUiFontSize);
      expect(prefs.codeFontSize, ChatPrefs.defaultCodeFontSize);
      expect(prefs.uiFontFamily, isNull);
    });
  });

  group('a size that arrives broken', () {
    test('too large clamps down rather than being taken at face value', () {
      expect(loadRaw({'uiFontSize': 999}).uiFontSize, ChatPrefs.maxUiFontSize);
      expect(
        loadRaw({'codeFontSize': 400}).codeFontSize,
        ChatPrefs.maxCodeFontSize,
      );
    });

    test('too small clamps up — including zero and negatives', () {
      expect(loadRaw({'uiFontSize': 0}).uiFontSize, ChatPrefs.minUiFontSize);
      expect(loadRaw({'uiFontSize': -3}).uiFontSize, ChatPrefs.minUiFontSize);
      expect(
        loadRaw({'codeFontSize': -1}).codeFontSize,
        ChatPrefs.minCodeFontSize,
      );
    });

    test('a non-number falls back instead of throwing', () {
      expect(
        loadRaw({'uiFontSize': 'abc'}).uiFontSize,
        ChatPrefs.defaultUiFontSize,
      );
      expect(
        loadRaw({'uiFontSize': null}).uiFontSize,
        ChatPrefs.defaultUiFontSize,
      );
      expect(
        loadRaw({'codeFontSize': <String>[]}).codeFontSize,
        ChatPrefs.defaultCodeFontSize,
      );
    });

    // NaN fails every comparison it takes part in, so `clamp` alone lets it
    // straight through — and a NaN font size renders nothing at all.
    test('NaN and infinity fall back, since clamp alone would pass them', () {
      expect(
        ChatPrefs.fromJson({'uiFontSize': double.nan}).uiFontSize,
        ChatPrefs.defaultUiFontSize,
      );
      expect(
        ChatPrefs.fromJson({'codeFontSize': double.infinity}).codeFontSize,
        ChatPrefs.defaultCodeFontSize,
      );
    });
  });

  group('a family that arrives broken', () {
    // An empty family is not a font: CoreText resolves it to nothing, and the
    // text it was applied to disappears. It has to read as "the default".
    test('an empty or blank family reads as the system font', () {
      expect(loadRaw({'uiFontFamily': ''}).uiFontFamily, isNull);
      expect(loadRaw({'uiFontFamily': '   '}).uiFontFamily, isNull);
      expect(loadRaw({'codeFontFamily': ''}).codeFontFamily, isNull);
    });

    test('a family is trimmed, so a stray space does not break the lookup', () {
      expect(loadRaw({'uiFontFamily': ' Menlo '}).uiFontFamily, 'Menlo');
    });

    test('a non-string family reads as the system font', () {
      expect(loadRaw({'uiFontFamily': 42}).uiFontFamily, isNull);
    });
  });

  group('round-trip', () {
    test('what is saved is what comes back', () {
      const prefs = ChatPrefs(
        uiFontFamily: 'Inter',
        codeFontFamily: 'JetBrains Mono',
        uiFontSize: 16,
        codeFontSize: 11,
      );
      final store = ChatPrefsStore(file: file)..save(prefs);
      final loaded = store.load();

      expect(loaded.uiFontFamily, 'Inter');
      expect(loaded.codeFontFamily, 'JetBrains Mono');
      expect(loaded.uiFontSize, 16);
      expect(loaded.codeFontSize, 11);
      expect(loaded, prefs, reason: 'equality must cover the new fields');
    });

    test('a half-step code size survives the trip', () {
      final store = ChatPrefsStore(file: file)
        ..save(const ChatPrefs(codeFontSize: 12.5));
      expect(store.load().codeFontSize, 12.5);
    });
  });

  group('copyWith', () {
    // The `?? this.x` idiom can't say "put it back to the system font" —
    // passing null reads as "leave it alone". Without the explicit flag,
    // choosing System in the picker would silently do nothing, which is the
    // same bug archiving hit with `archivedAt`.
    test('going back to the system font needs the clear flag, and works', () {
      const chosen = ChatPrefs(uiFontFamily: 'Inter', codeFontFamily: 'Menlo');

      expect(
        chosen.copyWith(uiFontFamily: null).uiFontFamily,
        'Inter',
        reason: 'a bare null must read as "unchanged"',
      );
      expect(chosen.copyWith(clearUiFontFamily: true).uiFontFamily, isNull);
      expect(
        chosen.copyWith(clearUiFontFamily: true).codeFontFamily,
        'Menlo',
        reason: 'clearing one family must not disturb the other',
      );
      expect(chosen.copyWith(clearCodeFontFamily: true).codeFontFamily, isNull);
    });

    test('a size change leaves the families alone', () {
      const chosen = ChatPrefs(uiFontFamily: 'Inter', uiFontSize: 14);
      final bigger = chosen.copyWith(uiFontSize: 18);
      expect(bigger.uiFontSize, 18);
      expect(bigger.uiFontFamily, 'Inter');
    });
  });

  group('FontPrefs', () {
    test('the scale is expressed against the size the app was drawn at', () {
      expect(const FontPrefs().uiScale, 1);
      expect(const FontPrefs(uiSize: 7).uiScale, 0.5);
      expect(const FontPrefs(uiSize: 21).uiScale, 1.5);
    });
  });
}
