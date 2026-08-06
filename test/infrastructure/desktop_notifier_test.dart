import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';
import 'package:grid_app/infrastructure/platform/desktop_notifier.dart';

/// Keeps every logged event so a test can count how often the notifier reached
/// for the platform — the ask itself can't be observed off a real desktop, but
/// its one-line verdict in the timeline can.
class _RecordingLog implements AppLog {
  final List<String> messages = [];

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => messages.add('$category: $message');
}

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

    test('asks for nothing, so a test never sees a permission dialog', () {
      expect(const NoopDesktopNotifier().ensurePermission(), completes);
    });
  });

  group('SystemDesktopNotifier', () {
    test('asks the OS once however many callers need permission', () async {
      // Two dialogs for one app is the bug this guards: the shell asks after
      // the first frame, and a result landing at the same moment asks again.
      final log = _RecordingLog();
      final notifier = SystemDesktopNotifier(log: log);
      addTearDown(notifier.dispose);

      await Future.wait([
        notifier.ensurePermission(),
        notifier.ensurePermission(),
      ]);

      expect(
        log.messages.where((m) => m.startsWith('notify: Notifications')),
        hasLength(1),
      );
    });

    test('stays silent — and unthrown — where the OS said no', () async {
      // Off a real desktop the platform always refuses. A refused notifier must
      // still swallow the banner: a delivered task result is not a failure
      // because its banner couldn't be posted.
      final log = _RecordingLog();
      final notifier = SystemDesktopNotifier(log: log);
      addTearDown(notifier.dispose);

      await notifier.show(
        const DesktopNotification(title: 'Daily brief', body: 'Done'),
      );

      expect(log.messages, contains('notify: Notifications off'));
      expect(
        log.messages,
        isNot(contains('notify: Could not post a notification')),
      );
    });
  });
}
