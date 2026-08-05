import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_log.dart';

/// One thing worth interrupting the user for: work that finished while they were
/// somewhere else.
///
/// [opens] is what clicking it should show — a conversation id — so the
/// notification is a way back into the app rather than a dead beep. Null when
/// there is nothing to open.
class DesktopNotification {
  const DesktopNotification({
    required this.title,
    required this.body,
    this.opens,
  });

  final String title;
  final String body;
  final String? opens;
}

/// Posts notifications to the desktop's own notification centre.
///
/// An interface because the app must stay testable off a real desktop: a
/// controller under test gets [NoopDesktopNotifier] (or a fake that records)
/// rather than a platform channel that isn't there.
abstract interface class DesktopNotifier {
  /// Show [notification]. Best-effort: a machine where notifications are denied
  /// or unsupported must not turn a delivered result into an error.
  Future<void> show(DesktopNotification notification);

  /// The [DesktopNotification.opens] values of notifications the user clicked —
  /// what the app should bring them to. Broadcast, and empty on a notifier that
  /// can't be clicked.
  Stream<String> get opened;
}

/// Whether finished work deserves an OS notification, or whether the user can
/// already see it.
///
/// The rule is deliberately narrow: **only** the exact thing they are looking at,
/// in a window that has focus, goes unannounced. A reply landing in a background
/// chat still gets a notification even though the app is on screen — the sidebar
/// row is easy to miss, and being told twice costs nothing next to never being
/// told at all.
///
/// Pure so the rule is tested rather than inferred from watching the app.
bool notificationIsWorthIt({
  required bool appFocused,
  required bool userIsLookingAtIt,
}) => !(appFocused && userIsLookingAtIt);

/// Does nothing, and says so honestly by never emitting a click.
///
/// The default everywhere, replaced in `main` once the real one has initialized:
/// a test, and any code path that runs before the platform plugin is ready, gets
/// silence instead of a channel error.
class NoopDesktopNotifier implements DesktopNotifier {
  const NoopDesktopNotifier();

  @override
  Future<void> show(DesktopNotification notification) async {}

  @override
  Stream<String> get opened => const Stream.empty();
}

/// The real one: `UNUserNotificationCenter` on macOS, the freedesktop
/// notification daemon on Linux, toast notifications on Windows.
///
/// Deliberately *not* the older `NSUserNotification` route some Flutter packages
/// still take — Apple has retired that API, and a notification that silently
/// does nothing is worse than none, because the feature looks shipped.
class SystemDesktopNotifier implements DesktopNotifier {
  SystemDesktopNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    AppLog log = const NoopAppLog(),
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _log = log;

  final FlutterLocalNotificationsPlugin _plugin;
  final AppLog _log;
  final _opened = StreamController<String>.broadcast();

  /// Each notification needs its own id or the next one replaces the last — two
  /// tasks finishing a minute apart would leave one banner.
  int _nextId = 0;
  bool _ready = false;

  @override
  Stream<String> get opened => _opened.stream;

  /// Ask the OS for permission and wire the click handler. Returns whether the
  /// notifier is usable — false when the platform refused, which is the caller's
  /// cue to keep the [NoopDesktopNotifier] rather than call into a dead plugin.
  Future<bool> initialize() async {
    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          macOS: DarwinInitializationSettings(
            // No badge: an unread count on the dock icon duplicates the badge
            // the sidebar already draws, and nothing in the app clears it.
            requestBadgePermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open Grid'),
          windows: WindowsInitializationSettings(
            appName: 'Grid',
            appUserModelId: _kBundleId,
            guid: _kWindowsActivationGuid,
          ),
        ),
        onDidReceiveNotificationResponse: _onClicked,
      );
      _ready = ok ?? false;
    } on Object catch (error, stackTrace) {
      _log.failure(
        'notify',
        'Desktop notifications unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> show(DesktopNotification notification) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: notification.title,
        body: notification.body,
        payload: notification.opens,
        notificationDetails: const NotificationDetails(
          macOS: DarwinNotificationDetails(presentBadge: false),
        ),
      );
    } on Object catch (error, stackTrace) {
      // A banner that couldn't be posted is not worth failing a delivery over —
      // but it is worth a line in the log, or "why didn't it tell me?" has no
      // answer anywhere on disk.
      _log.failure(
        'notify',
        'Could not post a notification',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _onClicked(NotificationResponse response) {
    final opens = response.payload;
    if (opens == null || opens.isEmpty) return;
    _opened.add(opens);
  }

  void dispose() => unawaited(_opened.close());
}

/// Matches `PRODUCT_BUNDLE_IDENTIFIER` in `macos/Runner/Configs/AppInfo.xcconfig`
/// — Windows wants the same identity in its own field.
const String _kBundleId = 'ai.autonomous.grid';

/// Windows routes a toast click back to the app through this GUID. Any stable
/// UUID works; it must simply never change, or clicks stop arriving.
const String _kWindowsActivationGuid = '8a4c1f6e-2b7d-4a19-9c33-5e0f7d1b6a24';

/// The app's notifier. [NoopDesktopNotifier] by default and overridden in `main`
/// with a [SystemDesktopNotifier] that initialized — the same shape as
/// [appLogProvider], and for the same reason: nothing under test should reach a
/// platform channel.
final desktopNotifierProvider = Provider<DesktopNotifier>(
  (ref) => const NoopDesktopNotifier(),
);
