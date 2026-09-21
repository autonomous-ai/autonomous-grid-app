import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/cell_credentials.dart';

/// A fixed clock, because every rule here is about time and waiting one out in
/// a test is how a suite gets slow and flaky at once.
const int _now = 1_700_000_000_000;

void main() {
  late CellCredentials credentials;

  setUp(() => credentials = CellCredentials());

  void mintInvite(String token, {String device = 'phone-1', int at = _now}) =>
      credentials.mint(
        token,
        deviceId: device,
        life: kInviteLife,
        singleUse: true,
        nowMs: at,
      );

  void mintResume(String token, {String device = 'phone-1', int at = _now}) =>
      credentials.mint(
        token,
        deviceId: device,
        life: kResumeLife,
        singleUse: false,
        nowMs: at,
      );

  group('a pairing code', () {
    test('admits the phone it was minted for', () {
      mintInvite('t');

      expect(credentials.spend('t', nowMs: _now + 1000), 'phone-1');
    });

    test('opens exactly one connection — a code read off a screen is a code '
        'somebody else may have read too', () {
      mintInvite('t');

      expect(credentials.spend('t', nowMs: _now), 'phone-1');
      expect(credentials.spend('t', nowMs: _now), isNull);
    });

    test('stops working after ten minutes, so a screenshot from this morning '
        'is not still a way in', () {
      mintInvite('t');

      final justInside = _now + kInviteLife.inMilliseconds - 1;
      final justOutside = _now + kInviteLife.inMilliseconds;

      expect(credentials.spend('t', nowMs: justOutside), isNull);
      // And the expired one is gone rather than lingering to be swept later.
      expect(credentials.length, 0);
      mintInvite('u');
      expect(credentials.spend('u', nowMs: justInside), 'phone-1');
    });
  });

  group('a way back in', () {
    test('is reusable, because its whole job is to spare re-pairing a phone '
        'that is already paired', () {
      mintResume('r');

      expect(credentials.spend('r', nowMs: _now), 'phone-1');
      expect(credentials.spend('r', nowMs: _now + 86400000), 'phone-1');
    });

    test('still ends, so a phone nobody has used for a month comes back '
        'through the front door', () {
      mintResume('r');

      expect(
        credentials.spend('r', nowMs: _now + kResumeLife.inMilliseconds),
        isNull,
      );
    });
  });

  group('taking a phone away', () {
    test('revoking drops every credential it could still have used — waiting '
        'for a resume to age out is a month of a lost phone getting in', () {
      mintInvite('i', device: 'lost');
      mintResume('r', device: 'lost');
      mintResume('other', device: 'kept');

      credentials.revokeFor('lost');

      expect(credentials.spend('i', nowMs: _now), isNull);
      expect(credentials.spend('r', nowMs: _now), isNull);
      expect(credentials.spend('other', nowMs: _now), 'kept');
    });
  });

  group('what is never admitted', () {
    test('a token nobody minted', () {
      expect(credentials.spend('made-up', nowMs: _now), isNull);
    });

    test('the empty string, which is what a missing field decodes to', () {
      expect(credentials.spend('', nowMs: _now), isNull);
    });
  });

  test('sweeping forgets what has aged out and keeps what has not, so a long '
      'session does not grow a map of dead tokens', () {
    mintInvite('old');
    mintResume('live');

    credentials.sweep(nowMs: _now + kInviteLife.inMilliseconds);

    expect(credentials.length, 1);
    expect(
      credentials.spend('live', nowMs: _now + kInviteLife.inMilliseconds),
      'phone-1',
    );
  });
}
