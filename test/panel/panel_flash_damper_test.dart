import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/panel/logic/panel_flash_damper.dart';

final _t0 = DateTime.utc(2026, 8, 25, 12);
DateTime _at(Duration d) => _t0.add(d);

const _mac = 'A4:CB:8F:CF:D0:78';

void main() {
  group('bounding what a wrong answer about firmware can cost', () {
    test('an image this board has not been given is allowed through', () {
      final damper = PanelFlashDamper();

      expect(damper.refuse(_mac, '0.1.28', _t0), isNull);
    });

    test('the same image is never written to the same board twice — the rule '
        'that actually breaks a reflash loop', () {
      // A board given this exact image that comes back asking for it again did
      // not fail to receive it: something else wrote over it, or its reported
      // version disagrees with what is in its flash. A second write cannot make
      // either of those untrue, and each one costs ~3 MB and a reboot.
      final damper = PanelFlashDamper()..wrote(_mac, '0.1.28', _t0);

      expect(
        damper.refuse(_mac, '0.1.28', _at(const Duration(seconds: 15))),
        contains('already been written'),
      );
    });

    test('a different image is still allowed after one was written, because a '
        'session really can need two', () {
      final damper = PanelFlashDamper()..wrote(_mac, '0.1.28', _t0);

      expect(
        damper.refuse(_mac, '0.1.29', _at(const Duration(minutes: 1))),
        isNull,
      );
    });

    test('the fourth write to one board in an hour is refused, whatever the '
        'version', () {
      final damper = PanelFlashDamper();
      for (var i = 0; i < kPanelFlashesPerHour; i++) {
        damper.wrote(_mac, '0.1.$i', _at(Duration(minutes: i)));
      }

      expect(
        damper.refuse(_mac, '0.9.9', _at(const Duration(minutes: 10))),
        contains('cap'),
      );
    });

    test('the cap is a moving hour, not a tally — writes age out of it', () {
      final damper = PanelFlashDamper();
      for (var i = 0; i < kPanelFlashesPerHour; i++) {
        damper.wrote(_mac, '0.1.$i', _at(Duration(minutes: i)));
      }

      expect(
        damper.refuse(_mac, '0.9.9', _at(const Duration(hours: 2))),
        isNull,
      );
    });

    test('one board hitting the cap says nothing about another — two panels '
        'can be plugged in and only one of them in trouble', () {
      final damper = PanelFlashDamper();
      for (var i = 0; i < kPanelFlashesPerHour; i++) {
        damper.wrote(_mac, '0.1.$i', _at(Duration(minutes: i)));
      }

      expect(damper.refuse('BB:BB:BB:BB:BB:BB', '0.9.9', _t0), isNull);
    });

    test('a board with no MAC is not counted at all, because every one of them '
        'would otherwise be the same board', () {
      // An empty MAC is what a greeting that omitted the field parses to. It
      // identifies nothing, so keying on it would let one anonymous device
      // exhaust the cap for every other.
      final damper = PanelFlashDamper()..wrote('', '0.1.28', _t0);

      expect(damper.refuse('', '0.1.28', _t0), isNull);
    });
  });
}
