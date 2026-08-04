import 'dart:async';

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
import '../logic/connector_category.dart';
import '../logic/connectors_controller.dart';
import '../logic/connectors_refresh.dart';
import '../logic/composio_toolkit.dart';
import 'widgets/connector_details_dialog.dart';
import 'widgets/connector_mark.dart';
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

/// Which half of the screen the user is looking at.
///
/// **Two, not three.** There was an "Available" pill beside these, and the
/// moment "All" stopped listing connected rows the two became the same view —
/// same rows, same order, same everything. Two controls that do one thing is
/// worse than one: pressing the second and seeing nothing change reads as a
/// broken filter. "Browse" is the honest name for what "All" now shows.
enum _ConnectorFilter {
  all('Browse'),
  connected('Connected');

  const _ConnectorFilter(this.label);

  final String label;

  /// **"All" means the whole directory, not "everything on this machine too".**
  ///
  /// It used to keep connected rows as well, which put them at the top of every
  /// view — the browsing one included. With seven of them that is 281px, 63% of
  /// the list area on a 700px window, leaving about one card's worth of room for
  /// the results the user came to look at (measured 2026-08-04).
  ///
  /// Filtering them *by category* was tried first and abandoned: the registry
  /// has no taxonomy, and searching for one puts Paradex — a crypto exchange —
  /// under Marketing while Gmail, Drive, Sheets and Jina match no category at
  /// all. A filter that silently drops six of seven connectors is worse than no
  /// filter.
  ///
  /// So the rule is the plain one, with no exception to remember: **connected
  /// connectors live under the Connected pill**. Tony chose this over keeping
  /// them on "All" and hiding them only once a category is picked — one rule
  /// beats a rule plus a special case.
  bool keeps(Connector connector) => switch (this) {
    all => !connector.connected,
    connected => connector.connected,
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

    // Two rows, because they answer different questions: the top one is about
    // *this install* — have I connected it — and the bottom is about the
    // directory's subject matter. Interleaved on one line they read as six
    // equal choices, and the ten subjects would push the status pills off the
    // scroll before anyone found them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _statusRow(browse, notifier),
        // Categories narrow the *directory*, so they go where the directory
        // does: hidden on Connected, which lists what this computer already
        // holds and never pages the registry at all.
        if (filter != _ConnectorFilter.connected) ...[
          const SizedBox(height: 8),
          _CategoryRow(
            selected: browse.category,
            onSelect: notifier.setCategory,
          ),
        ],
      ],
    );
  }

  /// **Scrolls horizontally.** Three status pills and a sort field is more than
  /// a narrow window holds — measured at 218px over on an 800px pane, which is
  /// an overflow stripe across the toolbar rather than a control that quietly
  /// wraps. Scrolling keeps every one of them reachable at any width, and at the
  /// sizes this app is normally used the row never moves.
  Widget _statusRow(
    BrowseConnectorsState browse,
    BrowseConnectorsController notifier,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
          // **No directory filter pills.** They were two more controls for a
          // distinction most people never make, and the shortlist they produced
          // broke paging: every Smithery-managed server is on page one, so
          // scrolling fetched more and the list never grew. Ordering carries the
          // quality signal instead — see `visibleServers`.
          if (filter != _ConnectorFilter.connected) ...[
            const SizedBox(width: 4),
            _BarDivider(),
            const SizedBox(width: 12),
            // `AppSelectField`, not a hand-rolled menu and certainly not
            // `DropdownButtonFormField`: this is the app's one select control and
            // it already owns the panel style, the radius and the hover.
            // `showLabel: false` because the row names it by position — a
            // "Sort" caption here would add height the pills beside it don't have
            // and knock the bar out of alignment.
            SizedBox(
              width: 150,
              child: AppSelectField<ComposioToolkitSort>(
                label: 'Sort',
                showLabel: false,
                value: browse.sort,
                options: [
                  for (final option in ComposioToolkitSort.values)
                    AppSelectOption(value: option, label: option.label),
                ],
                // Fires a refetch now, where it used to reorder rows already in
                // hand: the directory sorts its whole catalog, so the answer is
                // not derivable from the page on screen. The skeletons that
                // follow are the same ones a search shows.
                onChanged: notifier.setSort,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The subject pills: Finance, Developer, Design…
///
/// **One at a time, and none by default.** The directory opens on everything,
/// which is the honest starting point for a catalogue nobody has told us
/// anything about yet. Selecting is a narrowing; pressing the selected pill
/// again widens back out, which is the only way to undo one without a "Clear"
/// control that would sit unused for the whole time no category is chosen.
///
/// Single-select rather than multi: these are search terms, and the registry
/// ANDs them — "Finance" plus "Design" would ask for servers that are both,
/// which is close to none. A control that reliably empties the list is worse
/// than one that cannot express the combination.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.selected, required this.onSelect});

  final ConnectorCategory? selected;
  final ValueChanged<ConnectorCategory?> onSelect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // **Wraps, where the status row above scrolls.** Ten pills overflow every
    // window this app is used at, and a horizontal scroller hid the last two
    // behind an edge with nothing to say they were there — "Analytics" rendered
    // clipped mid-word. Wrapping shows all ten at any width and costs one extra
    // line only when the window is genuinely narrow. The row above keeps
    // scrolling because it holds three pills and a select field, which fit.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The label the row was missing: without it a second bank of pills
        // reads as more status filters rather than as a different question.
        Padding(
          padding: const EdgeInsets.only(top: 7, right: 10),
          child: Text(
            'Category',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final category in ConnectorCategory.values)
                PillChoice(
                  label: Text(category.label),
                  selected: category == selected,
                  // Pressing the live one clears it. See the note above:
                  // without this there is no way back to the whole directory.
                  onTap: () => onSelect(category == selected ? null : category),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What is running, kept beside what you are browsing.
///
/// **The problem it solves.** Connected connectors were moved off the Browse
/// view because seven of them took 281px — 63% of the list area on a 700px
/// window — and pushed the search results the user came for below the fold. That
/// fixed the crowding and created a new gap: nothing on screen said what was
/// already signed in, so "do I have Gmail?" meant switching tabs to find out.
///
/// A column answers both. It costs no vertical space at all, which is the axis
/// the grid actually competes for, and it is *always* the same seven rows — the
/// search box and the category pills never touch it, so it stays a stable
/// reference while everything to its left changes.
///
/// Rows, not cards: this is a list to scan down for a name, and the description
/// that makes a card worth its size is exactly the thing already known about a
/// connector you chose to sign in to.
class _ConnectedSidebar extends StatelessWidget {
  const _ConnectedSidebar({required this.connected});

  final List<Connector> connected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        // A raised surface with its own shadow, per §2: fill alone separates
        // nothing — `surfaceFill` is 1.13:1 against the page — so the shadow is
        // what actually lifts this off the pane, not decoration on top of it.
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Running',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: AppFont.medium,
                      letterSpacing: .06,
                      color: AppPalette.textFaint,
                    ),
                  ),
                ),
                Text(
                  '${connected.length}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: AppFont.medium,
                    color: AppPalette.textFaint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          // Scrolls rather than growing: a machine with twenty connectors must
          // not push its own column past the pane. `shrinkWrap` so a short list
          // takes only the height it needs and the panel ends under the last
          // row instead of running to the bottom of the screen.
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: connected.length,
              itemBuilder: (context, index) =>
                  _ConnectedSidebarRow(connector: connected[index]),
            ),
          ),
        ],
      ),
    );
  }
}

/// One running connector: its mark, its name, and whether it is usable.
class _ConnectedSidebarRow extends StatefulWidget {
  const _ConnectedSidebarRow({required this.connector});

  final Connector connector;

  @override
  State<_ConnectedSidebarRow> createState() => _ConnectedSidebarRowState();
}

class _ConnectedSidebarRowState extends State<_ConnectedSidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final connector = widget.connector;
    // Amber for signed-in-but-no-tools, which is a real state five connectors
    // sit in — green there would promise something the agent cannot do yet.
    final usable = connector.token?.isUsable ?? true;
    final tint = usable ? AppPalette.online : AppPalette.warn;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => showConnectorDetailsDialog(
          context,
          connector,
          actionBuilder: (close) => ConnectorAction(
            connector: connector,
            onSettled: close,
            labelled: true,
          ),
        ),
        child: AnimatedContainer(
          duration: AppMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              ConnectorMark(
                imageUrl: connector.imageUrl,
                fallbackIcon: Icons.link_rounded,
                size: 22,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  connector.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: _hovered
                        ? AppPalette.textPrimary
                        : AppPalette.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
              ),
            ],
          ),
        ),
      ),
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
            // **Bounded, and that is structural rather than cosmetic.** This
            // line sits under a list that has already claimed the pane, so its
            // height comes out of whatever slack is left. A registry error is
            // an arbitrary sentence — long enough to wrap to three lines and
            // overflow the Column by exactly the 20px the first bug report
            // showed. Two lines is what the leftover reliably affords, and an
            // ellipsis says plainly that there is more.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
    // grid, so the list does not reflow when they are replaced.
    if (browse.loading) return const _DirectorySkeletonGrid();

    if (browse.error != null) {
      // Not an `ErrorBox`: the gateway's connectors are fine and the screen
      // works. A directory that could not be reached is a missing *addition*,
      // and shouting about it would misreport the state of everything above.
      return _DirectoryNote(
        '${browse.error} The rest of this list is unaffected.',
      );
    }

    if (!browse.hasMore) return const SizedBox.shrink();

    // **No button.** Reaching the end of the scroll is the request now
    // (`ExtensionGrid.onReachedEnd`), so this only reports. The space is still
    // held while a page is in flight: an indicator that appears and disappears
    // under the pointer moves the cards above it, and the whole point of paging
    // on scroll is that the list does not jump.
    return SizedBox(
      height: 40,
      child: Center(
        child: browse.loadingMore
            // The list stays put and only this changes — the distinction
            // `loading` and `loadingMore` exist to make.
            ? const AppSpinner(size: SpinnerSize.medium)
            : Text(
                'Scroll for more',
                style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        // **One row, not two.** This block sits under a `Flexible` list that has
        // already claimed the pane, so its height comes out of the slack the
        // list left. Two rows of cards asked for 66px where 46 were going, and
        // overflowed by exactly the 20 the error reported.
        for (var row = 0; row < 1; row++)
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

class _ConnectorsViewState extends ConsumerState<ConnectorsView> {
  _ConnectorFilter _filter = _ConnectorFilter.all;

  /// Holds the keystrokes back so the registry sees words, not letters.
  ///
  /// 350ms: long enough that typing "notion" is one request instead of six,
  /// short enough that the list moves while the user is still looking at the
  /// box. `_generation` in the controller covers the rest — a slow answer to an
  /// abandoned query cannot land whatever this interval is.
  Timer? _debounce;

  /// A keystroke has landed and the registry has not been asked yet.
  ///
  /// **The 350ms above is a hole the controller's own `loading` cannot cover.**
  /// It is false until `search()` runs, while the local `matches` test has
  /// already emptied the list — so for the length of the debounce the screen
  /// showed "No matches" about a query nobody had sent. Same bug as the one
  /// during the request, a third of a second earlier, and it needs its own flag
  /// because only this widget knows a timer is pending.
  bool _typing = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (!_typing) setState(() => _typing = true);
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      // Cleared here rather than when the answer lands: `search()` sets
      // `loading` in the same turn, so the two flags hand over without a frame
      // in between where both are false and the empty state flashes.
      setState(() => _typing = false);
      ref.read(browseConnectorsProvider.notifier).search(query);
    });
  }

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
      if (browse.entries.isEmpty && !browse.loading && browse.error == null) {
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
      // Wider than the shared 940, and the sidebar is why. That cap is a
      // *reading measure* for the screens that are columns of rows; this one is
      // a grid, so width buys columns rather than line length. At 940 the pane
      // could not reach the sidebar's 1164px threshold even maximised on a
      // 1884px display — measured, and the reason the column never appeared.
      //
      // 1200 clears it with the grid still at three 312px cards. Not more: past
      // this the cards stop reading as a grid and start reading as a table.
      maxContentWidth: 1200,
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
      // Sent to the registry as well as matched locally. The local pass keeps
      // the connected rows searchable — they are not in the directory — while
      // this reaches the 4,000 the loaded page is a slice of.
      onQueryChanged: _onQueryChanged,
      filterBar: _FilterBar(
        filter: _filter,
        onFilter: (option) => setState(() => _filter = option),
      ),
      listBuilder: (context, {required filtered, required matches}) {
        // Filtered once, read twice — by the list, and by the decision of
        // whether the directory's footer has anything to sit under. Two copies
        // of this comprehension is two chances for the footer to appear over an
        // empty state, which is the layout that overflowed.
        // **A directory row is not re-tested against the search text.** The
        // registry has already answered it, and it matches on more than a name
        // and a blurb: searching `email` returns `mailerlite` and
        // `reckon/email-verifier`, neither of which carries the word where this
        // local test can see it. Applying `matches` on top threw those away —
        // the registry found 132 servers and the screen showed almost none.
        //
        // The local test still governs everything else, which is what keeps a
        // connected connector findable: those come from the token store and the
        // agent's config, and the registry has never heard of them.
        //
        // `matches` answers true for every row while the box is empty, so this
        // reads the same when nobody is searching.
        List<Connector> visible(List<Connector> all) => [
          for (final connector in all)
            if (_filter.keeps(connector) &&
                (connector.catalogEntry != null ||
                    matches(connector.name, connector.description)))
              connector,
        ];
        return switch (ref.watch(connectorsProvider)) {
          // **`ConnectorList` must be the flexible child.** It renders an
          // `ExtensionGrid`, which is a `CustomScrollView`, and a viewport needs
          // a bounded height on its scroll axis. Dropped straight into a Column
          // it gets an unbounded one, throws `debugCheckHasBoundedAxis`, and
          // takes the *whole screen* down with it — not just the list: the
          // failed layout leaves every ancestor unlaid-out, so the pane renders
          // blank with the toolbar still drawn above it.
          //
          // The siblings then have to be *small*, and stay small: whatever the
          // list does not take, they share. `_DirectoryTail` is one row of
          // controls and `_DirectoryNote` one line of text, both well under the
          // slack a `Flexible` list leaves them. A block of any real height here
          // overflows the moment the list fills the pane — measured at exactly
          // 20px when the tail rendered a two-row skeleton grid.
          // **`hasValue`, not `AsyncData`.** A provider that is re-running holds
          // `AsyncLoading` *with the previous value attached*, which the
          // `AsyncData` pattern does not match — so every rebuild of this chain
          // fell through to the skeletons and swapped the whole list out and
          // back. That is the blink at the bottom of the list: not a slow
          // fetch, a screen that threw away rows it still had.
          //
          // Reading the value instead means a reload is invisible unless it
          // changes something, which is the behaviour a list being appended to
          // has to have.
          AsyncValue(:final value?) => _ConnectorsBody(
            rows: visible(value),
            // Straight off the full list, not off `visible` — which drops every
            // connected row by design, so filtering it here would always be
            // empty. Untouched by the search box and the category pills too:
            // this is "what is running", and it stays the same answer whatever
            // the user happens to be looking for.
            connected: [
              for (final connector in value)
                if (connector.connected) connector,
            ],
            // A category counts as narrowing. Without it, picking one that
            // returns nothing renders "No connectors yet" — the empty state for
            // a machine with nothing set up — when the truth is that this
            // subject came back empty.
            filtered:
                filtered ||
                _filter != _ConnectorFilter.all ||
                ref.watch(
                  browseConnectorsProvider.select((s) => s.category != null),
                ),
            // `search()` clears the rows and sets `loading` together, so
            // without this the empty list in between renders as "No matches"
            // — a verdict on a search that has not come back yet.
            searching:
                _typing ||
                ref.watch(browseConnectorsProvider.select((s) => s.loading)),
            showingConnected: _filter == _ConnectorFilter.connected,
            showDirectoryTail: _filter != _ConnectorFilter.connected,
            onLoadMore: () =>
                ref.read(browseConnectorsProvider.notifier).loadMore(),
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

/// The assembled screen body: the note, the list, and the directory's footer.
///
/// Split out so the layout rule below lives in one place with the reason for it,
/// rather than inline in a `switch` arm three levels deep.
class _ConnectorsBody extends StatelessWidget {
  const _ConnectorsBody({
    required this.rows,
    required this.connected,
    required this.filtered,
    required this.searching,
    required this.showingConnected,
    required this.showDirectoryTail,
    required this.onLoadMore,
  });

  final List<Connector> rows;

  /// Everything signed in on this machine, for the sidebar. Unfiltered — see
  /// the note at the call site.
  final List<Connector> connected;

  final bool filtered;

  /// The directory has been asked and has not answered. Kept distinct from
  /// [filtered]: one describes the question, the other whether it has a result.
  final bool searching;

  /// The Connected pill is selected. Passed explicitly rather than derived from
  /// `!showDirectoryTail`: the two happen to agree today, and a screen whose
  /// empty-state wording depends on a *footer* flag is one rename away from
  /// telling users the wrong thing.
  final bool showingConnected;

  final bool showDirectoryTail;

  /// Fetch the directory's next page. Safe to call repeatedly — see
  /// `ExtensionGrid.onReachedEnd`.
  final VoidCallback onLoadMore;

  /// Below this the sidebar is dropped and the grid gets the whole pane.
  ///
  /// **Measured, not guessed.** Three cards at their 300px target plus two 10px
  /// gaps is 920px of grid; add the 14px scroll gutter, the 216px sidebar and
  /// the 14px between them and the pane has to be 1164px before the sidebar is
  /// free. Below that it costs a column — 940px drops the grid from three cards
  /// to two, and 760px drops it to one, which is a list pretending to be a grid.
  ///
  /// So the sidebar is a *reward for a wide window*, not a fixture. Maximised on
  /// a 1080p display the pane is ~1640px and it always shows; the narrow window
  /// in the report that prompted this keeps its three columns instead.
  static const double _sidebarBreakpoint = 1164;
  static const double _sidebarWidth = 216;
  static const double _sidebarGap = 14;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Never on the Connected pill: that view *is* the list of connected
        // connectors, and a sidebar repeating it beside itself is the same
        // content twice.
        final showSidebar =
            !showingConnected &&
            connected.isNotEmpty &&
            constraints.maxWidth >= _sidebarBreakpoint;

        final list = _list();
        if (!showSidebar) return list;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: list),
            const SizedBox(width: _sidebarGap),
            SizedBox(
              width: _sidebarWidth,
              child: _ConnectedSidebar(connected: connected),
            ),
          ],
        );
      },
    );
  }

  Widget _list() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `Expanded`, so the list is handed what its siblings leave rather than
        // taking the pane and pushing them off it. `ConnectorList` renders an
        // `ExtensionGrid` — a `CustomScrollView` — and a viewport needs a
        // bounded height on its scroll axis. Dropped into a Column without
        // this it gets an unbounded one, throws `debugCheckHasBoundedAxis`, and
        // takes the **whole pane** down: a failed layout leaves every ancestor
        // unlaid-out, so the screen renders blank with the toolbar still drawn.
        Expanded(
          child: ConnectorList(
            // A status pill narrows the list just like a search does: sections
            // collapse (they'd all be one status anyway) and an empty result
            // reads as "nothing matched", not "nothing configured".
            filtered: filtered,
            searching: searching,
            showingConnected: showingConnected,
            connectors: rows,
            // Paging happens by scrolling, so the request belongs to the thing
            // that scrolls. `loadMore` is a no-op unless there is a further
            // page and none is in flight, which is what makes it safe to call
            // on every frame near the bottom.
            onReachedEnd: showDirectoryTail ? onLoadMore : null,
            // **Inside the scroll view, not under it.** A footer below the
            // viewport is a fixed block competing with the list for the pane's
            // height: reserving 46px for it left the empty state 209 of the
            // 229 it centres, and the screen overflowed by exactly the 20px the
            // first report showed. As a sliver it costs the list nothing and
            // scrolls into view where it belongs — after the last card.
            footer: rows.isNotEmpty && showDirectoryTail
                ? const _DirectoryTail(visible: true)
                : null,
          ),
        ),
      ],
    );
  }
}
