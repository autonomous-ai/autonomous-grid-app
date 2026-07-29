import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/connector_refresh_service.dart';

/// Starts the connector token refresh schedule for the life of the app.
///
/// A widget rather than a call in `main()` because the service reads providers,
/// and the `ProviderScope` those live in only exists inside the tree. It draws
/// nothing and rebuilds nothing — [child] is passed straight through.
///
/// Placed above the router so the schedule runs whether or not anyone opens the
/// Connectors screen. That is the point: the tokens are for the agent, and the
/// agent is used from chat, not from Settings.
class ConnectorRefreshScope extends ConsumerStatefulWidget {
  const ConnectorRefreshScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ConnectorRefreshScope> createState() =>
      _ConnectorRefreshScopeState();
}

class _ConnectorRefreshScopeState extends ConsumerState<ConnectorRefreshScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: the sweep talks to the network and the disk, and
    // doing that during the first build would delay the window appearing for a
    // round trip the user is not waiting on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(connectorRefreshServiceProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
