import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../features/projects/logic/project_folder_status.dart';
import '../features/provider_node/logic/provider_run_controller.dart';

/// Watches the window's own life: every way the app can quit, so a running engine
/// is stopped before the process exits — otherwise the detached `grid join` engine
/// keeps serving on the relay with no app to manage or stop it — and its coming
/// back to the front, so what the app believes about the user's folders is asked
/// again rather than assumed.
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

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Stop any engine we're serving. Best-effort and time-boxed so a wedged CLI
  /// can never trap the user in an app that refuses to quit.
  Future<void> _stopServing() async {
    if (_stopped) return;
    _stopped = true;
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
  void onWindowFocus() => revalidateProjectFolders(ref);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Both hooks, because only together do they cover the platforms: clicking the
    // window fires [onWindowFocus], while ⌘-tabbing back to a hidden app arrives
    // as `resumed`. Re-asking is a handful of async stats, so being told twice
    // costs nothing and being told never costs a badge that lies all session.
    if (state == AppLifecycleState.resumed) revalidateProjectFolders(ref);
  }

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
