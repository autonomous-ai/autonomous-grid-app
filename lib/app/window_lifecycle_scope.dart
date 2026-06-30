import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../features/provider_node/logic/provider_run_controller.dart';

/// Intercepts the window close so any engine we're serving is stopped before the
/// process exits — otherwise the detached `grid join` engine keeps serving on
/// the relay with no app to manage or stop it. Relies on `setPreventClose(true)`
/// (set in `main`); the OS close button and the tray's "Quit" both route here.
/// Renders [child] unchanged.
class WindowLifecycleScope extends ConsumerStatefulWidget {
  const WindowLifecycleScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowLifecycleScope> createState() =>
      _WindowLifecycleScopeState();
}

class _WindowLifecycleScopeState extends ConsumerState<WindowLifecycleScope>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    // shutdownServing is already best-effort and time-boxed, but cap the whole
    // step too so a wedged CLI can never trap the user in an unclosable window.
    await ref
        .read(providerRunControllerProvider.notifier)
        .shutdownServing()
        .timeout(const Duration(seconds: 8), onTimeout: () {});
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
