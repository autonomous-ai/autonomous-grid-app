import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../features/auth/logic/session_controller.dart';
import '../features/projects/logic/project_folder_status.dart';
import '../features/provider_node/logic/provider_run_controller.dart';
import '../infrastructure/analytics/analytics_events.dart';
import '../infrastructure/analytics/analytics_providers.dart';
import '../infrastructure/platform/window_focus.dart';

/// Watches the window's own life: every way the app can quit, so a running engine
/// is stopped before the process exits — otherwise the detached `grid join` engine
/// keeps serving on the relay with no app to manage or stop it — and its coming
/// and going at the front, which answers two questions. What the app believes
/// about the user's folders is asked again rather than assumed, and
/// [windowFocusedProvider] knows whether anyone is watching — the difference
/// between a finished reply that beeps and one that doesn't need to.
///
/// Two exit paths must be covered, and only together do they catch a normal
/// quit: the window's close button and the tray's "Quit" arrive via
/// [onWindowClose] (`setPreventClose(true)` in `main` routes them here), while
/// **⌘Q**, the app menu's Quit and an OS log-out arrive via [didRequestAppExit] —
/// which `setPreventClose` does *not* cover. Missing the second path is why a
/// ⌘Q used to leave `llama-server` running after the window was gone. A hard kill
/// (`kill -9`, a crash, stopping `flutter run` from the terminal) can't be
/// intercepted by anything; that engine is instead adopted and managed on the
/// next launch (see `ProviderRunController.reconcile`). Renders [child] unchanged.
class WindowLifecycleScope extends ConsumerStatefulWidget {
  const WindowLifecycleScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowLifecycleScope> createState() =>
      _WindowLifecycleScopeState();
}

class _WindowLifecycleScopeState extends ConsumerState<WindowLifecycleScope>
    with WindowListener, WidgetsBindingObserver {
  /// Guards the async teardown from running twice — if a single quit somehow
  /// fires both hooks, or fires again while the first is still in flight.
  bool _stopped = false;

  /// When this launch started, so the quit event can say how long the app was
  /// open. Stamped here rather than in `main` because this is also where the
  /// matching `app_opened` goes out.
  final DateTime _openedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: `ref.read` during `initState` is legal, but a
    // provider that reads `~/.grid` on the way up has no business running
    // before the window has painted (conventions §2).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(analyticsProvider)
          .appOpened(signedIn: ref.read(sessionProvider).isLoggedIn);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Close the launch out: the last analytics event, then any engine we're
  /// serving. Both best-effort and time-boxed, so neither a wedged network nor
  /// a wedged CLI can trap the user in an app that refuses to quit.
  Future<void> _stopServing() async {
    if (_stopped) return;
    _stopped = true;
    // Both time-boxed inside themselves, and analytics goes first so its last
    // event is queued before the eight seconds an engine may take to stop.
    final analytics = ref.read(analyticsProvider);
    analytics.appClosed(open: DateTime.now().difference(_openedAt));
    await analytics.close();
    await ref
        .read(providerRunControllerProvider.notifier)
        .shutdownServing()
        .timeout(const Duration(seconds: 8), onTimeout: () {});
  }

  @override
  Future<void> onWindowClose() async {
    await _stopServing();
    await windowManager.destroy();
  }

  @override
  void onWindowFocus() {
    _setFocused(focused: true);
    revalidateProjectFolders(ref);
  }

  @override
  void onWindowBlur() => _setFocused(focused: false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Both hooks, because only together do they cover the platforms: clicking the
    // window fires [onWindowFocus], while ⌘-tabbing back to a hidden app arrives
    // as `resumed`. Re-asking is a handful of async stats, so being told twice
    // costs nothing and being told never costs a badge that lies all session.
    if (state == AppLifecycleState.resumed) {
      _setFocused(focused: true);
      revalidateProjectFolders(ref);
      return;
    }
    // Anything else — hidden, minimised, another app in front — means the user
    // isn't watching, which is exactly when finished work deserves a banner.
    _setFocused(focused: false);
  }

  void _setFocused({required bool focused}) =>
      ref.read(windowFocusedProvider.notifier).set(focused: focused);

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // ⌘Q / the app-menu Quit / an OS log-out don't route through onWindowClose,
    // so stop the engine here too before letting the exit proceed.
    await _stopServing();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
