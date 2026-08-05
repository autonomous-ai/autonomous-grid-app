import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/platform/desktop_notifier.dart';

void main() {
  group('notificationIsWorthIt', () {
    test('stays quiet only about the thing on screen in a focused window', () {
      expect(
        notificationIsWorthIt(appFocused: true, userIsLookingAtIt: true),
        isFalse,
      );
    });

    test('announces a reply that landed in a chat behind the open one', () {
      // The app being on screen is not the same as this chat being read — the
      // sidebar row is easy to miss, and a missed reply is the failure that
      // matters.
      expect(
        notificationIsWorthIt(appFocused: true, userIsLookingAtIt: false),
        isTrue,
      );
    });

    test('announces work that finished while the app was behind something', () {
      expect(
        notificationIsWorthIt(appFocused: false, userIsLookingAtIt: true),
        isTrue,
      );
      expect(
        notificationIsWorthIt(appFocused: false, userIsLookingAtIt: false),
        isTrue,
      );
    });
  });

  group('NoopDesktopNotifier', () {
    test('swallows a notification instead of failing the work behind it', () {
      expect(
        const NoopDesktopNotifier().show(
          const DesktopNotification(title: 'Daily brief', body: 'Done'),
        ),
        completes,
      );
    });

    test('never claims a click, so nothing waits on one that cannot come', () {
      expect(const NoopDesktopNotifier().opened, emitsDone);
    });
  });
}
