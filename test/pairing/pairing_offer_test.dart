import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'e2ee_test_bytes.dart';

/// The pairing code is the only thing that crosses from the computer to the
/// phone out of band, and it carries the key everything else is checked
/// against. A phone that misreads one either fails to connect or — much worse
/// — pins the wrong key.
void main() {
  PairingOffer offer() => PairingOffer(
    deviceToken: 'a' * 48,
    hostPublicKey: repeatedBytes(7),
    hostName: 'MacBookPro2021.local',
    relay: const PairingRelayEndpoint(
      cellUrl: 'ws://127.0.0.1:8787',
      relayHostId: 'AbCdEf0123_-xyZ9',
      inviteToken: 'k0riOIn93GB_gmAR2gToTUIH1rcFxXnJ8cXj8WCv5t8',
      inviteExpiresAtMs: 1789441592612,
    ),
  );

  test(
    'a code this computer wrote is a code the phone reads back unchanged',
    () {
      final parsed = PairingOffer.parse(offer().toLink());

      expect(parsed, isNotNull);
      expect(parsed!.deviceToken, 'a' * 48);
      expect(parsed.hostPublicKey, repeatedBytes(7));
      expect(parsed.hostName, 'MacBookPro2021.local');
      expect(parsed.relay.relayHostId, 'AbCdEf0123_-xyZ9');
      expect(parsed.relay.inviteExpiresAtMs, 1789441592612);
    },
  );

  test('the bare code parses too, because what a person copies off a screen is '
      'one or the other and they cannot be expected to know which', () {
    final link = offer().toLink();
    final bare = link.substring('grid://pair?code='.length);

    expect(PairingOffer.parse(bare)?.deviceToken, 'a' * 48);
  });

  test(
    'a link is url-safe and unpadded, so it survives a QR and a text field',
    () {
      final link = offer().toLink();
      expect(link, startsWith('grid://pair?code='));

      // The code itself, not the scheme in front of it.
      final code = link.substring('grid://pair?code='.length);
      expect(code, isNot(contains('=')), reason: 'padding survives badly');
      expect(code, isNot(contains('+')));
      expect(code, isNot(contains('/')));
      expect(code, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    },
  );

  test('another grid:// route is refused, so only the pairing link may carry '
      'auth material', () {
    final code = offer().toLink().substring('grid://pair?code='.length);

    expect(PairingOffer.parse('grid://pairing?code=$code'), isNull);
    expect(PairingOffer.parse('grid://open?code=$code'), isNull);
    expect(PairingOffer.parse('grid://pair/extra?code=$code'), isNull);
  });

  test('a host key that is not 32 canonical base64 bytes is refused, because a '
      'phone that pins a mangled key can never match the real one', () {
    final link = offer().toLink();
    expect(PairingOffer.parse(link), isNotNull);

    for (final broken in ['', 'AAAA', 'not base64 at all !!']) {
      expect(
        _withField(link, 'hostPublicKeyB64', broken),
        isNull,
        reason: broken,
      );
    }
  });

  test('a cell address that is not a bare ws origin is refused, so a code can '
      'never point a phone at a path somebody chose', () {
    final link = offer().toLink();

    for (final bad in [
      'http://127.0.0.1:8787',
      'ws://127.0.0.1:8787/somewhere',
      'ws://127.0.0.1:8787?x=1',
      'not a url',
      '',
    ]) {
      expect(_withRelayField(link, 'cellUrl', bad), isNull, reason: bad);
    }
  });

  test('a host id that is not sixteen base64url characters is refused', () {
    final link = offer().toLink();

    for (final bad in ['short', 'AbCdEf0123_-xyZ', 'AbCdEf0123_-xyZ9!']) {
      expect(_withRelayField(link, 'relayHostId', bad), isNull, reason: bad);
    }
  });

  test('nonsense and oversized input are refused rather than thrown on, since '
      'this reads whatever was in someone\'s clipboard', () {
    expect(PairingOffer.parse(''), isNull);
    expect(PairingOffer.parse('   '), isNull);
    expect(PairingOffer.parse('hello'), isNull);
    expect(PairingOffer.parse('grid://pair'), isNull);
    expect(PairingOffer.parse('x' * (kPairingLinkMaxCharacters + 1)), isNull);
  });
}

PairingOffer? _withField(String link, String field, Object? value) =>
    PairingOffer.parse(_rewrite(link, (json) => json[field] = value));

PairingOffer? _withRelayField(String link, String field, Object? value) =>
    PairingOffer.parse(
      _rewrite(link, (json) => (json['relay']! as Map)[field] = value),
    );

String _rewrite(String link, void Function(Map<String, Object?>) change) {
  final code = link.substring('grid://pair?code='.length);
  final json = _decodeJson(code) as Map<String, Object?>;
  change(json);
  return 'grid://pair?code=${_encodeJson(json)}';
}

Object? _decodeJson(String code) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(code))));

String _encodeJson(Map<String, Object?> json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
