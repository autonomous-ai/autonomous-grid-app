import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/panel/panel_stranger.dart';

/// One clock for the whole file — [PanelStrangerWatch] takes the time rather
/// than reading it, which is the only reason a twelve-second window can be
/// tested in a millisecond.
final _t0 = DateTime.utc(2026, 8, 25, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  group('deciding a port belongs to another product', () {
    test('a port that has delivered nothing is not a stranger, however long '
        'it stays quiet — a sleeping panel is not a foreign one', () {
      // The failure this rules out: a machine with a panel that is powered but
      // silent would otherwise be disowned on a timer, over and over, and the
      // app would spend its life reopening a port it just let go of.
      final watch = PanelStrangerWatch();

      expect(watch.isStranger(_at(600)), isFalse);
    });

    test('bytes that never become a frame are a stranger once the window is '
        'up, because that is the one signal the two products differ on', () {
      final watch = PanelStrangerWatch()..heard(4096, _at(0));

      expect(watch.isStranger(_at(11)), isFalse);
      expect(watch.isStranger(_at(13)), isTrue);
      expect(watch.reason(_at(13)), contains('4096 bytes'));
    });

    test('one decoded frame settles it for good, even if the port then goes '
        'quiet past the window', () {
      // A frame that decoded passed this build's magic AND its CRC. The other
      // product's stream cannot do both, so a single clean decode is proof of
      // ownership and nothing later should reopen the question.
      final watch = PanelStrangerWatch()
        ..heard(64, _at(0))
        ..decoded();

      expect(watch.isStranger(_at(600)), isFalse);
      expect(watch.reason(_at(600)), isNull);
    });

    test('the window runs from the first byte, not from the first call — a '
        'board that starts talking late still gets its full twelve seconds', () {
      // This app's own panel is silent-then-noisy across a reboot: the ROM and
      // the bootloader print before the firmware frames anything. Timing from
      // anywhere earlier would evict a board that was merely booting.
      final watch = PanelStrangerWatch()..heard(10, _at(50));

      expect(watch.isStranger(_at(60)), isFalse);
      expect(watch.isStranger(_at(63)), isTrue);
    });

    test('an empty read starts nothing — it is what a rebooted panel delivers '
        'forever, and it is not a sign of life', () {
      final watch = PanelStrangerWatch()..heard(0, _at(0));

      expect(watch.isStranger(_at(600)), isFalse);
    });

    test('a greeting naming another product needs no window at all', () {
      final watch = PanelStrangerWatch()..foreignGreeting();

      expect(watch.isStranger(_at(0)), isTrue);
      expect(watch.reason(_at(0)), contains('another product'));
    });

    test('a foreign greeting outranks a decoded frame, because sharing the '
        'framing is exactly the case this survives', () {
      // Only reachable if the two products ever share a magic again. If they
      // do, frames WILL decode and the greeting is the only thing left that
      // tells them apart — so it has to win.
      final watch = PanelStrangerWatch()
        ..heard(64, _at(0))
        ..decoded()
        ..foreignGreeting();

      expect(watch.isStranger(_at(0)), isTrue);
    });

    test('closing forgets the port, so the next one is judged on its own '
        'bytes rather than on what used to be plugged in', () {
      final watch = PanelStrangerWatch()..heard(4096, _at(0));
      expect(watch.isStranger(_at(13)), isTrue);

      watch.closed();

      expect(watch.isStranger(_at(13)), isFalse);
      expect(watch.bytes, 0);
    });
  });
}
