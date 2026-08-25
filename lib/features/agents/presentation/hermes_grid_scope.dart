import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/adapters/hermes_grid_link.dart';
import '../logic/adapters/hermes_tool.dart';

/// Keeps `~/.hermes` pointed at the grid the app has selected, for the life of
/// the app.
///
/// Scheduled tasks don't run in this app: Hermes's own scheduler daemon runs
/// them, out of the `~/.hermes/config.yaml` this app last wrote. Only two things
/// ever wrote it — sending a Hermes chat message, and saving a task — so a user
/// who switched grids, or who chats with Claude Code instead, left every task
/// firing against a grid the app had walked away from. On 2026-08-21 that was
/// two daily tasks failing for two days with `503 No providers available`,
/// because nobody was sharing anything on the grid they were still aimed at.
///
/// A widget above the router rather than a call in `main()`, for the same reason
/// as [ConnectorRefreshScope]: it reads providers, and it has to run whether or
/// not anyone opens the Scheduled screen — which is the whole point, since the
/// screen is exactly what nobody is looking at when a task fires at 8am.
class HermesGridScope extends ConsumerStatefulWidget {
  const HermesGridScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HermesGridScope> createState() => _HermesGridScopeState();
}

class _HermesGridScopeState extends ConsumerState<HermesGridScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: this writes two files under `~/.hermes` and re-arms
    // the saved tasks through the `hermes cron` CLI, and the window opening is
    // not waiting on any of it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  @override
  Widget build(BuildContext context) {
    // Keyed on the id, not the credential: a `grid sync` hands back a new
    // object for the same grid, and re-pointing on each of those would rewrite
    // Hermes's config — and re-arm every task — for nothing.
    ref.listen(
      selectedNetworkProvider.select((network) => network?.networkId),
      (_, _) => _follow(),
    );
    return widget.child;
  }

  Future<void> _follow() async {
    if (!mounted) return;
    // Nothing of Hermes's to point at on a machine that doesn't have it —
    // writing `~/.hermes` here would invent a config for a program that was
    // never installed.
    if (ref.read(hermesPathProvider) == null) return;
    final error = await ref
        .read(hermesGridLinkProvider)
        .ensureModelForSelectedGrid();
    if (error == null) return;
    // Not a toast: nobody asked for this, it runs on launch and on every grid
    // switch, and the task's own screen already says why it can't run. But it
    // is the moment the tasks stopped following the app, so it goes on the
    // record — "my tasks stopped running" is otherwise invisible.
    ref
        .read(appLogProvider)
        .warn('tasks', "scheduled tasks aren't on this grid: $error");
  }
}
