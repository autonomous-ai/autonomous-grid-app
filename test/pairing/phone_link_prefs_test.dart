import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/phone_link_prefs.dart';

/// Whether this computer answers a paired phone, across launches.
///
/// The link used to go back to off every time Grid started, so a phone standing
/// next to an open computer was told it was offline. Remembering the choice is
/// the fix — and the thing this file guards is that it stays a *memory* and
/// never becomes a default.
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

  test('a computer that has never shared with a phone announces nothing, '
      'because there is no file to say otherwise', () async {
    expect(await prefs.read(), isNull);
  });

  test('remembers being switched on, with the relay it was pointed at — the '
      'address is half the choice', () async {
    await prefs.writeOn('ws://127.0.0.1:8787');

    final choice = await prefs.read();

    expect(choice!.on, isTrue);
    expect(choice.cellUrl, 'ws://127.0.0.1:8787');
  });

  test('remembers being switched off just as firmly, so quitting the link does '
      'not un-quit itself on the next launch', () async {
    await prefs.writeOn('ws://127.0.0.1:8787');
    await prefs.writeOff('ws://127.0.0.1:8787');

    expect((await prefs.read())!.on, isFalse);
  });

  test('a corrupt file reads as no choice rather than throwing: the worst case '
      'has to be "does not come back on by itself", never "the app will not '
      'start"', () async {
    file.writeAsStringSync('{ not json');

    expect(await prefs.read(), isNull);
  });

  test('a file from a build that wrote a different shape is ignored, not '
      'guessed at — an unreadable choice is not a choice', () async {
    file.writeAsStringSync(
      jsonEncode({'v': 99, 'on': true, 'cellUrl': 'ws://x'}),
    );

    expect(await prefs.read(), isNull);
  });

  test('a record with no relay address is ignored, since there is nowhere to '
      'reconnect to', () async {
    file.writeAsStringSync(jsonEncode({'v': 1, 'on': true}));

    expect(await prefs.read(), isNull);
  });

  test('is readable only by its owner: it decides whether this machine answers '
      'a phone, so another account must not be able to flip it', () async {
    await prefs.writeOn('ws://127.0.0.1:8787');

    final mode = file.statSync().mode & 0x1FF;
    expect(mode, 0x180, reason: 'expected 0600, got ${mode.toRadixString(8)}');
  });
}
