import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/panel/panel_message.dart';
import 'package:grid_app/infrastructure/panel/panel_silence.dart';

/// The clock is passed in, so these are ordinary assertions rather than a test
/// that waits twenty seconds.
void main() {
  final t0 = DateTime.utc(2026, 8, 17, 21, 45);

  group('when the app gives up on a port handle', () {
    test(
      'a panel plugged in and heard from is not stale, however long the app runs',
      () {
        final watch = PanelSilenceWatch()..opened(t0);
        watch.heard(t0.add(const Duration(minutes: 9)));

        expect(
          watch.isStale(t0.add(const Duration(minutes: 9, seconds: 19))),
          isFalse,
        );
      },
    );

    test(
      'a handle that stops producing bytes is stale, which is the only way a '
      'rebooted panel can be told from an idle one',
      () {
        final watch = PanelSilenceWatch()..opened(t0);

        expect(watch.isStale(t0.add(const Duration(seconds: 19))), isFalse);
        expect(watch.isStale(t0.add(const Duration(seconds: 21))), isTrue);
      },
    );

    test(
      'a machine with nothing plugged in is never stale — otherwise it would '
      'reopen a port it never had, on a timer, forever',
      () {
        final watch = PanelSilenceWatch()
          ..opened(t0)
          ..closed();

        expect(watch.isStale(t0.add(const Duration(hours: 1))), isFalse);
      },
    );

    test('every byte counts as life, not only the answer to a ping', () {
      // A firmware transfer or a voice capture fills the link with traffic that
      // is not a pong. Timing those out would abort the transfer that proves the
      // link is working.
      final watch = PanelSilenceWatch()..opened(t0);
      for (var second = 5; second <= 60; second += 5) {
        watch.heard(t0.add(Duration(seconds: second)));
      }

      expect(watch.isStale(t0.add(const Duration(seconds: 65))), isFalse);
    });

    test('the window is longer than the panel\'s own 15s rule for the reverse '
        'silence, so one late message cannot trip both at once', () {
      expect(kPanelSilenceLimit.inSeconds, greaterThan(15));
    });
  });

  group('the answer to a ping', () {
    test('parses as its own message, so it is not logged as unreadable every '
        'five seconds for the life of the session', () {
      expect(PanelInbound.parse('{"t":"pong"}'), isA<PanelPong>());
    });
  });
}
