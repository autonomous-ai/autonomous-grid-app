import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/phone_link_prefs.dart';

/// Whether this computer shares with a phone, across launches.
///
/// Sharing used to go back to off every time Grid started, so a phone standing
/// next to an open computer was told it was offline. Remembering the choice is
/// the fix — and what this file guards is that it stays a *memory* and never
/// becomes a default: what comes back on launch is a server on a public address,
/// and nothing may switch that on because an app opened.
void main() {
  late Directory root;
  late File file;
  late PhoneLinkPrefs prefs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('grid-phone-link-prefs');
    file = File('${root.path}/phone_link.json');
    prefs = PhoneLinkPrefs(file: file);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a computer that has never shared with a phone opens nothing, because '
      'there is no file to say otherwise', () async {
    expect(await prefs.isOn(), isFalse);
  });

  test('remembers being switched on, which is the whole reason a phone can '
      'reach a computer that was merely restarted', () async {
    await prefs.write(on: true);

    expect(await prefs.isOn(), isTrue);
  });

  test('remembers being switched off just as firmly, so turning sharing off '
      'does not un-turn-off itself on the next launch', () async {
    await prefs.write(on: true);
    await prefs.write(on: false);

    expect(await prefs.isOn(), isFalse);
  });

  test(
    'a corrupt file reads as off rather than throwing: the worst case has to '
    'be "does not come back by itself", never "the app will not start"',
    () async {
      file.writeAsStringSync('{ not json');

      expect(await prefs.isOn(), isFalse);
    },
  );

  test(
    'a file from the build that also stored a relay address still counts as '
    'switched on — updating Grid must not silently stop answering a phone',
    () async {
      file.writeAsStringSync(
        jsonEncode({'v': 1, 'on': true, 'cellUrl': 'ws://127.0.0.1:8787'}),
      );

      expect(await prefs.isOn(), isTrue);
    },
  );

  test(
    'a file from a build that wrote some other shape is ignored, not guessed '
    'at — an unreadable choice is not a choice',
    () async {
      file.writeAsStringSync(jsonEncode({'v': 99, 'on': true}));

      expect(await prefs.isOn(), isFalse);
    },
  );

  test('is readable only by its owner: it decides whether this machine answers '
      'a phone, so another account must not be able to flip it', () async {
    await prefs.write(on: true);

    final mode = file.statSync().mode & 0x1FF;
    expect(mode, 0x180, reason: 'expected 0600, got ${mode.toRadixString(8)}');
  });
}
