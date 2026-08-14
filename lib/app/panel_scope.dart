import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/panel/logic/panel_controller.dart';
import '../infrastructure/panel/panel_link_provider.dart';

/// Opens the link to a Grid Panel for the life of the app.
///
/// A widget rather than a call in `main()` because the port and the controller
/// are providers, and the `ProviderScope` those live in only exists inside the
/// tree. It draws nothing and rebuilds nothing — [child] is passed straight
/// through.
///
/// Placed above the router so a panel works whatever the window is showing.
/// That is the point of the device: it answers to the desk, not to whichever
/// screen happens to be open.
class PanelScope extends ConsumerStatefulWidget {
  const PanelScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PanelScope> createState() => _PanelScopeState();
}

class _PanelScopeState extends ConsumerState<PanelScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: finding the panel shells out to `ioreg`, which
    // costs the better part of a second, and no one is waiting on a device that
    // may not even be plugged in.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Answering is wired before the port opens. The panel introduces itself
      // the moment it sees the port, and that handshake is a broadcast message
      // — with no listener it is dropped, not queued.
      ref.read(panelControllerProvider).listen();
      await ref.read(panelPortProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
