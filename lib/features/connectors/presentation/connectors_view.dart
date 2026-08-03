import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_tile_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../../shared/widgets/pill_choice.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/browse_connectors_controller.dart';
import '../logic/connector.dart';
import '../logic/connectors_controller.dart';
import '../logic/connectors_refresh.dart';
import '../logic/smithery_server.dart';
import 'widgets/add_mcp_dialog.dart';
import 'widgets/browse_connectors_dialog.dart';
import 'widgets/connector_list.dart';

/// Whether the toolbar offers the **Browse dialog** — a separate window onto the
/// same directory.
///
/// **This no longer gates whether the directory is reachable.** Its rows are on
/// the screen itself now, merged into the catalog under Available, with the
/// registry's own Verified filter and a sort beside the status pills. The dialog
/// is a second, modal way to the same place, and two entrances to one directory
/// is one more than the screen needs — so it stays off while the inline path is
/// the one being used.
///
/// Kept as a `const false` rather than deleted, for the reason D26 gave: a
/// branch behind a constant is still type-checked, while commented-out code
/// rots silently. Everything it reaches — [showBrowseConnectorsDialog], its
/// controller, its client — is still compiled and still tested.
///
/// The one thing that moves with it is the accent: with Browse gone, "Add
/// custom" takes the primary fill, because a toolbar carrying only the quiet
/// button reads as a screen with nothing to do.
const bool kShowBrowseConnectors = false;

/// What connects the assistant to the outside: the MCP servers in the agent's
/// config, and the catalog of services a future sign-in will connect in one
/// step. The config is the only truth about what's live — the catalog only
/// adds "available" rows under it.
class ConnectorsView extends ConsumerStatefulWidget {
  const ConnectorsView({super.key});

  @override
  ConsumerState<ConnectorsView> createState() => _ConnectorsViewState();
}

enum _ConnectorFilter {
  all('All'),
  connected('Connected'),
  available('Available');

  const _ConnectorFilter(this.label);

  final String label;

  bool keeps(Connector connector) => switch (this) {
    all => true,
    connected => connector.connected,
    available => !connector.connected,
  };
}

/// One of this screen's two toolbar actions.
///
/// Local rather than `ExtensionCreateButton` because this screen is the only one
/// with *two* ways to add something, so it is the only one that has to decide
/// which of them is the primary. Every other screen has a single create action
/// and keeps the shared button; changing that one to take a variant would push
/// this screen's problem onto four that don't have it.
///
/// The geometry — 34px, radius 11, `AppGlass.cardShadow` — is copied from the
/// shared pair on purpose: these sit in the same row as the refresh button, and
/// a toolbar whose buttons are two heights reads as broken before it reads as
/// deliberate.
///
/// [accent] carries the primary. **Browse holds it**: the directory is where
/// someone who does not already have a URL can actually get somewhere, and Add
/// custom is for the narrower case of already knowing the address. Two accent
/// buttons side by side would make the screen ask which is the real one.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette/AppGlass.
    // White on accent is the shared button's own pairing, kept rather than
    // re-derived: `AppPalette.accent` is tuned as a fill for exactly this ink.
    // The quiet variant takes the default text colour, which resolves per theme.
    final ink = accent ? Colors.white : null;
    return Material(
      color: accent ? AppPalette.accent : AppGlass.surfaceFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: ink),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: ink,
                  fontSize: 13,
                  // The heavier weight belongs to the primary, not to the
                  // label: it is half of what makes one of these read as the
                  // action to take.
                  fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The status pills, plus the directory's own filter and sort.
///
/// One row rather than two: they narrow the same list, and stacking them would
/// imply the second applies to the result of the first. It does not — the status
/// pills filter what has been assembled, while Verified is a term the *registry*
/// applies before anything is fetched.
///
/// A `ConsumerWidget` of its own so a directory page landing rebuilds this bar
/// and not the whole screen — the list below is expensive and has nothing to
/// re-read.
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filter, required this.onFilter});

  final _ConnectorFilter filter;
  final ValueChanged<_ConnectorFilter> onFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final browse = ref.watch(browseConnectorsProvider);
    final notifier = ref.read(browseConnectorsProvider.notifier);

    return Row(
      children: [
        for (final option in _ConnectorFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PillChoice(
              label: Text(option.label),
              selected: option == filter,
              onTap: () => onFilter(option),
            ),
          ),
        // Only offered where it can do something. Under Connected every row is
        // already on this machine, and a directory term cannot narrow that.
        if (filter != _ConnectorFilter.connected) ...[
          const SizedBox(width: 4),
          _BarDivider(),
          const SizedBox(width: 12),
          for (final option in SmitheryFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChoice(
                label: Text(option.label),
                selected: browse.filters.contains(option),
                // Inert rather than hidden while the registry is answering: a
                // pill that vanishes mid-press moves the ones beside it, and a
                // second toggle would start a search that supersedes the first
                // anyway.
                onTap: browse.loading
                    ? () {}
                    : () => notifier.toggleFilter(option),
              ),
            ),
          const SizedBox(width: 4),
          // `AppSelectField`, not a hand-rolled menu and certainly not
          // `DropdownButtonFormField`: this is the app's one select control and
          // it already owns the panel style, the radius and the hover.
          // `showLabel: false` because the row names it by position — a
          // "Sort" caption here would add height the pills beside it don't have
          // and knock the bar out of alignment.
          SizedBox(
            width: 150,
            child: AppSelectField<SmitheryServerSort>(
              label: 'Sort',
              showLabel: false,
              value: browse.sort,
              options: [
                for (final option in SmitheryServerSort.values)
                  AppSelectOption(value: option, label: option.label),
              ],
              onChanged: notifier.setSort,
            ),
          ),
        ],
      ],
    );
  }
}

/// A hairline between two groups of pills that narrow different things.
class _BarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: 1,
      height: 18,
      color: AppPalette.textFaint.withValues(alpha: 0.25),
    );
  }
}

/// A quiet line about the directory, sitting above the list it describes.
class _DirectoryNote extends StatelessWidget {
  const _DirectoryNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 15, color: AppPalette.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The directory's skeletons, Load more, count and errors — everything about the
/// public registry that is not a row.
///
/// Below the connector list rather than in place of it. The gateway's rows are
/// already on screen by the time the registry answers, and replacing them with
/// skeletons for a third party's page would take working connectors off the
/// screen to report on an addition to it.
class _DirectoryTail extends ConsumerWidget {
  const _DirectoryTail({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    if (!visible) return const SizedBox.shrink();
    final browse = ref.watch(browseConnectorsProvider);

    // First page in flight: cards the same shape as the real ones, on the same
    // two-up grid, so the list does not reflow when they are replaced.
    if (browse.loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: _DirectorySkeletonGrid(),
      );
    }

    if (browse.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        // Not an `ErrorBox`: the gateway's connectors are fine and the screen
        // works. A directory that could not be reached is a missing *addition*,
        // and shouting about it would misreport the state of everything above.
        child: _DirectoryNote(
          '${browse.error} The rest of this list is '
          'unaffected.',
        ),
      );
    }

    if (!browse.hasMore) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Center(
        child: browse.loadingMore
            // The list stays put and only this changes — the distinction
            // `loading` and `loadingMore` exist to make.
            ? const AppSpinner(size: SpinnerSize.medium)
            : _LoadMoreButton(
                onPressed: () =>
                    ref.read(browseConnectorsProvider.notifier).loadMore(),
              ),
      ),
    );
  }
}

/// Placeholder cards on the connector grid, for the directory's first page.
class _DirectorySkeletonGrid extends StatelessWidget {
  const _DirectorySkeletonGrid();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      children: [
        for (var row = 0; row < 2; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Opacity(
              // Fading down says "more below" rather than ending on a hard edge
              // — the same trick `ExtensionLoadingRows` uses.
              opacity: 1 - row * 0.35,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col > 0) const SizedBox(width: 8),
                    const Expanded(child: _DirectorySkeletonCard()),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One placeholder card, on the same grid as a real connector card: a 30px
/// mark, a 12px gap, then the name and blurb lines.
class _DirectorySkeletonCard extends StatelessWidget {
  const _DirectorySkeletonCard();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ExtensionTileSurface(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Skeleton(width: 30, height: 30, radius: 9),
                SizedBox(width: 12),
                Skeleton(width: 96, height: 13),
              ],
            ),
            const SizedBox(height: 14),
            const Skeleton(height: 11),
            const SizedBox(height: 7),
            const Skeleton(width: 160, height: 11),
          ],
        ),
      ),
    );
  }
}

/// The directory's Load more control.
class _LoadMoreButton extends StatefulWidget {
  const _LoadMoreButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends State<_LoadMoreButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Owns its own hover, rather than reading a parent's: a parent that tracks
    // the whole row cannot tell "on the button" from "near it", and the glyph
    // would sit at its resting colour under the pointer.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.expand_more_rounded,
                size: 17,
                // Full colour on hover: a glyph that stays dim under the
                // pointer reads as decoration.
                color: _hovered
                    ? AppPalette.textPrimary
                    : AppPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Load more',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _hovered
                      ? AppPalette.textPrimary
                      : AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectorsViewState extends ConsumerState<ConnectorsView> {
  _ConnectorFilter _filter = _ConnectorFilter.all;

  @override
  void initState() {
    super.initState();
    // After the first frame: the directory is a network round trip, and doing
    // it during the first build would hold the screen back for rows that are an
    // addition to it rather than the point of it. The gateway's connectors
    // render meanwhile.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final browse = ref.read(browseConnectorsProvider);
      // Only once. This screen is rebuilt on every mutation, and re-searching
      // on each would throw away the user's paging and their place in the list.
      if (browse.servers.isEmpty && !browse.loading && browse.error == null) {
        ref.read(browseConnectorsProvider.notifier).search('');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ExtensionScreen(
      title: 'Connectors',
      subtitle:
          'Connect the assistant to tools outside this computer — a database, '
          'a design tool, a web service.',
      searchHint: 'Search connectors',
      // Two ways in, so the toolbar owns the button rather than taking the
      // standard one. They are genuinely different questions — "find me
      // something" and "I already have an address" — and a menu would hide the
      // first behind a press for no gain: there are only two.
      //
      // "Add custom", not "Add an MCP server": the rest of this screen speaks in
      // Connect/Disconnect, and a user who doesn't know what MCP is can't tell
      // how that button differs from the Connect on every row.
      createButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kShowBrowseConnectors) ...[
            _ToolbarButton(
              icon: Icons.travel_explore_rounded,
              label: 'Browse',
              accent: true,
              onPressed: () => showBrowseConnectorsDialog(context),
            ),
            const SizedBox(width: 8),
          ],
          _ToolbarButton(
            icon: Icons.add_rounded,
            label: 'Add custom',
            // The accent follows whichever button is the primary one present,
            // rather than staying pinned to Browse: a toolbar whose only button
            // is the quiet fill reads as a screen with no action to take.
            accent: !kShowBrowseConnectors,
            onPressed: () => showAddMcpDialog(context),
          ),
        ],
      ),
      // The same definition of "reload" the mutations use, so the button can't
      // drift from them as sources are added.
      onRefresh: () => refreshConnectorsFromWidget(ref),
      filterBar: _FilterBar(
        filter: _filter,
        onFilter: (option) => setState(() => _filter = option),
      ),
      listBuilder: (context, {required filtered, required matches}) {
        final browse = ref.watch(browseConnectorsProvider);
        return switch (ref.watch(connectorsProvider)) {
          AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Said before the list, because it explains what the list *is*.
              // A lit-up Verified pill over rows the registry chose on relevance
              // alone would read as a promise the screen cannot keep.
              if (browse.filtersSuspended)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: _DirectoryNote(
                    'Showing search results — the directory can filter or '
                    'search, not both. Clear the search to use Verified.',
                  ),
                ),
              ConnectorList(
                // A status pill narrows the list just like a search does:
                // sections collapse (they'd all be one status anyway) and an
                // empty result reads as "nothing matched", not "nothing
                // configured".
                filtered: filtered || _filter != _ConnectorFilter.all,
                connectors: [
                  for (final connector in value)
                    if (_filter.keeps(connector) &&
                        matches(connector.name, connector.description))
                      connector,
                ],
              ),
              // The directory's own tail: skeletons while its first page is in
              // flight, then Load more. Below the list rather than replacing it
              // — the gateway's connectors are already on screen and blanking
              // them for a third party's page would be the worse trade.
              _DirectoryTail(
                // Under Connected the directory contributes nothing, so its
                // footer would be a control for rows that are not there.
                visible: _filter != _ConnectorFilter.connected,
              ),
            ],
          ),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read the connectors: $error",
          ),
          _ => const ExtensionLoadingRows(),
        };
      },
    );
  }
}
