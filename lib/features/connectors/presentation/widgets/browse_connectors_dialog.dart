import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/extension_toolbar.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/mcp_server.dart';
import '../../logic/browse_connectors_controller.dart';
import '../../logic/connector_link_controller.dart';
import '../../logic/connectors_controller.dart';
import '../../logic/mcp_auth_probe.dart';
import '../../logic/connector_catalog.dart';
import 'add_mcp_dialog.dart';
import 'connector_mark.dart';

/// Browse the public directory of hosted MCP servers and connect one.
///
/// A dialog rather than a screen because it is a *detour*: the user came to the
/// Connectors page to see what they have, and this answers "what else is there"
/// without losing that place. It also means the list underneath refreshes into
/// view the moment a connection lands, with nothing to navigate back to.
Future<void> showBrowseConnectorsDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _BrowseDialog());

class _BrowseDialog extends ConsumerStatefulWidget {
  const _BrowseDialog();

  @override
  ConsumerState<_BrowseDialog> createState() => _BrowseDialogState();
}

class _BrowseDialogState extends ConsumerState<_BrowseDialog> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// Keystrokes are not searches.
  ///
  /// Typing "notion" unthrottled is six requests to a third-party directory for
  /// one intention, five of which are already stale when they answer. The
  /// controller's generation counter makes those harmless; this makes them not
  /// happen.
  Timer? _debounce;

  /// How close to the bottom starts the next page, in pixels.
  ///
  /// Roughly four rows: far enough that the page is usually there before the
  /// reader arrives, close enough that a browse of the first screen doesn't
  /// silently pull three more. Triggering *at* the bottom is what makes infinite
  /// lists feel like they stutter — the wait begins only once there is nothing
  /// left to read.
  static const double _prefetchMargin = 320;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Deferred: the provider is read for the first time here, and mutating a
    // provider during the first build of a widget that watches it is an error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(browseConnectorsProvider.notifier).search('');
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.removeListener(_onScroll);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Fetch the next page as the bottom comes into view.
  ///
  /// Fires on every scroll frame and is *meant* to: `loadMore` returns
  /// immediately unless there is a page to get and nothing already in flight, so
  /// the guard lives in one place rather than being re-derived here. The one
  /// condition this does add is [BrowseConnectorsState.error] — without it a
  /// failed page would be retried on every pixel of scroll, hammering the
  /// directory with the request that just failed.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent - _prefetchMargin) return;
    final state = ref.read(browseConnectorsProvider);
    if (state.error != null || !state.hasMore) return;
    ref.read(browseConnectorsProvider.notifier).loadMore();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) ref.read(browseConnectorsProvider.notifier).search(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Dialog content: watch brightness so tokens re-color on a theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final state = ref.watch(browseConnectorsProvider);

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 22, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 20),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Browse connectors',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppIconButton(
                icon: Icons.close,
                size: 18,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            // Says what the list *is*, and the one thing about it that matters
            // before pressing anything: these are other people's servers.
            //
            // The directory is not named, deliberately. Which registry these
            // rows come from is a fact about this build, not about the user's
            // decision — and naming it invites the reader to weigh a brand they
            // have no way to judge instead of the server in front of them. It
            // would also age badly: the day a second source is added, every
            // sentence naming one of them is wrong.
            'Hosted MCP servers you can connect in one step. Signing in happens '
            'with the server itself, not with Grid.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
              height: 1.45,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        // Fixed rather than shrink-wrapped. The content grows by a page at a
        // time, and a dialog that resizes on Load more walks its own buttons out
        // from under the pointer.
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExtensionSearchField(
              controller: _search,
              hintText: 'Search the directory',
              onChanged: _onQueryChanged,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _Body(state: state, scroll: _scroll),
            ),
          ],
        ),
      ),
    );
  }
}

/// The list, or whatever stands in for it.
class _Body extends ConsumerWidget {
  const _Body({required this.state, required this.scroll});

  final BrowseConnectorsState state;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The first page, with nothing to keep on screen: skeletons rather than a
    // spinner, because the shape of what is coming is known exactly and the
    // layout must not jump when it lands.
    if (state.loading) return const _LoadingRows();

    if (state.error != null && state.entries.isEmpty) {
      return ErrorBox(message: state.error!);
    }

    if (state.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Nothing found',
        message: state.query.isEmpty
            ? "The directory didn't return anything. Try again shortly."
            : 'No server in the directory matches "${state.query}".',
      );
    }

    // The already-configured servers, so a row the user has can say so instead
    // of offering to add it twice.
    //
    // Matched on **URL, not name**: the config key is the user's to change, and
    // a name match would call a hand-typed "notion" pointing somewhere else
    // connected. The URL is what actually decides whether these are the same
    // server.
    final configured = switch (ref.watch(mcpServersProvider)) {
      AsyncData(:final value) => {
        for (final server in value)
          if (server.transport case McpHttp(:final url)) url.trim(),
      },
      _ => const <String>{},
    };

    return ListView.separated(
      controller: scroll,
      // One past the rows: the footer carries Load more, the appending spinner,
      // and the "that's everything" line — all three are about the list as a
      // whole and none belongs on a row.
      itemCount: state.entries.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == state.entries.length) return _Footer(state: state);
        final server = state.entries[index];
        return _ServerRow(
          server: server,
          connected: configured.contains(server.mcpUrl),
        );
      },
    );
  }
}

/// One directory entry: its mark, what it is, and the way in.
class _ServerRow extends ConsumerStatefulWidget {
  const _ServerRow({required this.server, required this.connected});

  /// A directory row, in the app's own catalog type rather than any one
  /// directory's. The field keeps its name because everything below reads
  /// `server.…`; what changed is where the row comes from.
  ///
  /// **This dialog only knows how to connect a self-serve row** — it probes the
  /// address and drives the sign-in itself. Rows from a brokered directory carry
  /// no address and are linked through the gateway instead, which is what
  /// `connectCatalog` is for. The dialog is behind `kShowBrowseConnectors`,
  /// which is false, so nothing reaches this today; re-enabling it means routing
  /// through `connectCatalog` rather than the probe below.
  final ConnectorCatalogEntry server;
  final bool connected;

  @override
  ConsumerState<_ServerRow> createState() => _ServerRowState();
}

class _ServerRowState extends ConsumerState<_ServerRow> {
  bool _busy = false;

  /// A config key not already taken.
  ///
  /// The directory's qualified name is unique *there*; this config may already
  /// hold something under it — a hand-added server, or the same one connected
  /// through the gateway. Suffixing rather than overwriting, because the entry
  /// that exists is working and the user did not ask for it to be replaced.
  String _freeName(Set<String> taken) {
    final base = widget.server.code;
    if (!taken.contains(base)) return base;
    for (var n = 2; n < 100; n++) {
      if (!taken.contains('$base-$n')) return '$base-$n';
    }
    return base;
  }

  /// Connect, by exactly the path a typed URL takes.
  ///
  /// Probe first, then hand the *same* [McpAuthProbeResult] to `connectDirect` —
  /// the discovery is not repeated, and the branch it decides is the branch the
  /// Add dialog would have taken for this address. Nothing about the directory
  /// leaks past this point: what lands in the store is a token keyed by name and
  /// a URL, indistinguishable from one added by hand.
  Future<void> _connect() async {
    final toast = ToastScope.of(context);
    final navigator = Navigator.of(context);
    final server = widget.server;

    setState(() => _busy = true);
    final probe = await ref.read(mcpAuthProbeProvider).probe(server.mcpUrl);
    if (!mounted) return;

    if (!probe.canSelfRegister) {
      // The app cannot be its own OAuth client here, so there is nothing to
      // press through. Hand the address to the form that has a Headers box
      // instead of dead-ending — the user keeps the URL they chose, and the
      // dialog they land on is the one that can finish the job.
      setState(() => _busy = false);
      navigator.pop();
      final reason = switch (probe.kind) {
        McpAuthKind.unreachable =>
          "${server.label} didn't answer. Its address is filled in — try "
              'again from here.',
        _ =>
          '${server.label} needs a token you provide. Its address is '
              'filled in.',
      };
      toast?.show(ToastSpec(message: reason, severity: ToastSeverity.info));
      await showAddMcpDialog(
        context,
        initialName: server.code,
        initialUrl: server.mcpUrl,
      );
      return;
    }

    final taken = switch (ref.read(mcpServersProvider)) {
      AsyncData(:final value) => {for (final s in value) s.name},
      _ => <String>{},
    };
    final name = _freeName(taken);

    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .connectDirect(connector: name, mcpUrl: server.mcpUrl, probe: probe);

    // The toast is not guarded on `mounted` and the state update is — the same
    // split `ConnectorAction._connect` settled on. This row can be disposed
    // while the browser is open (a re-search rebuilds the list), and returning
    // early on `!mounted` is exactly what made connect outcomes silent there.
    if (mounted) setState(() => _busy = false);
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : ToastSpec(
              message: '${server.label} is connected.',
              severity: ToastSeverity.success,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    final server = widget.server;
    final link = ref.watch(connectorLinkControllerProvider);
    final waiting = link.isPending(server.code);

    return ExtensionTileSurface(
      // The rows sit on a raised dialog, not on the page — without this they
      // measure 1.023:1 against it and vanish.
      onDialog: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConnectorMark(
            imageUrl: server.imageUrl,
            fallbackIcon: Icons.link_rounded,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The name alone. A "Verified" tag was on nearly every row —
                // the directory hands it out widely enough that it separated
                // nothing — and a badge that never varies is read as decoration
                // the first time and as noise every time after.
                Text(
                  server.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (server.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    server.description,
                    // Two lines, not one. These are community descriptions
                    // written as a sentence rather than a label, and one line
                    // truncates most of them mid-clause; three would let a
                    // verbose entry set the height of every row around it.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Action(
            connected: widget.connected,
            busy: _busy,
            waiting: waiting,
            onConnect: _connect,
            onCancel: () =>
                ref.read(connectorLinkControllerProvider.notifier).cancel(),
          ),
        ],
      ),
    );
  }
}

/// The one control a directory row offers, chosen by state.
///
/// Same four states and the same reasoning as `_CatalogAction` on the Connectors
/// screen: while the browser is open the way out is Cancel rather than a spinner
/// that strands the user, and a row already configured offers nothing.
class _Action extends StatelessWidget {
  const _Action({
    required this.connected,
    required this.busy,
    required this.waiting,
    required this.onConnect,
    required this.onCancel,
  });

  final bool connected;
  final bool busy;
  final bool waiting;
  final VoidCallback onConnect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (waiting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSpinner(size: SpinnerSize.small, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      );
    }
    if (busy) return const AppSpinner(size: SpinnerSize.small);
    // Already in the agent's config. A tag rather than a disabled button: there
    // is no action here, and a greyed Connect reads as one that failed.
    if (connected) return const ExtensionTag(label: 'Connected');
    return FilledButton(onPressed: onConnect, child: const Text('Connect'));
  }
}

/// Load more, the append spinner, and the end of the list.
class _Footer extends StatelessWidget {
  const _Footer({required this.state});

  final BrowseConnectorsState state;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);

    // A failure while appending, with rows still on screen. Shown here rather
    // than replacing the list: the pages already loaded are still good, and
    // throwing them away to report that the *next* one failed loses more than
    // it explains.
    if (state.error != null && state.entries.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ErrorBox(message: state.error!),
      );
    }

    // Reaching this footer *is* the request: the list prefetches 320px before
    // the bottom, so by the time it is on screen a page is in flight or about to
    // be. Both read as the same thing to the user — more is coming — and drawing
    // them differently would flicker between two footers a frame apart.
    if (state.loadingMore || state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            const AppSpinner(size: SpinnerSize.small),
            const SizedBox(height: 10),
            // Progress, not a promise — the directory stops handing rows over
            // long before `totalCount`, so this says how many are *on screen*
            // out of how many matched, and never claims the rest are reachable.
            Text(
              '${state.entries.length} of ${state.totalCount} matches',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ),
      );
    }

    // Said out loud, and only once there is something to have reached the end
    // of. A list that simply stops leaves the reader wondering whether it is
    // still loading — which, with no button left to press, is the only signal
    // they have.
    //
    // Two endings, because the directory has two. `totalCount` is how many
    // servers *match*; `totalPages` is how many the registry will actually hand
    // over, and they are not the same number — a plain `is:remote` query reports
    // ~3,999 matches and stops dead at 500 rows, whatever the page size (page 11
    // of 50 comes back an empty array; measured 2026-07-31). Claiming "all
    // 3,999" at row 500 would be a straight lie, and "End of results" alone
    // would read as a bug to anyone who saw the count. So the capped ending says
    // what happened and what to do about it.
    final capped = state.entries.length < state.totalCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          capped
              ? '${state.entries.length} of ${state.totalCount} matches — '
                    'search to narrow it down'
              : 'All ${state.entries.length} servers',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textFaint,
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows in the shape of the real ones.
///
/// The counts and widths are the row's own: a 30pt mark, a short title line, two
/// body lines. Getting these wrong is worse than a spinner — the list settles
/// into a different shape than it promised, which is the exact jump a skeleton
/// exists to prevent.
class _LoadingRows extends StatelessWidget {
  const _LoadingRows();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      // The wait is not interactive, and a skeleton list that scrolls invites
      // the reader to look for content underneath it.
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => const ExtensionTileSurface(
        onDialog: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 30/10 is `ConnectorMark`'s own geometry, copied so the placeholder
            // occupies the exact plate the logo will land on.
            Skeleton(width: 30, height: 30, radius: 10),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 3),
                  Skeleton.text(width: 140, height: 11),
                  SizedBox(height: 9),
                  Skeleton.text(height: 9),
                  SizedBox(height: 6),
                  Skeleton.text(width: 220, height: 9),
                ],
              ),
            ),
            SizedBox(width: 12),
            Skeleton(width: 74, height: 30, radius: 9),
          ],
        ),
      ),
    );
  }
}
