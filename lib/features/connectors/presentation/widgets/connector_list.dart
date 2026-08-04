import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/widgets/extension_grid.dart';
import '../../../../shared/widgets/extension_list.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../agents/logic/connector_runtime.dart';
import '../../../agents/logic/mcp_server.dart';
import '../../../agents/logic/rest_entry.dart';
import '../../logic/connector.dart';
import '../../logic/connector_catalog.dart';
import '../../logic/connector_link_controller.dart';
import '../../logic/connectors_controller.dart';
import 'add_mcp_dialog.dart';
import 'connector_details_dialog.dart';
import 'connector_mark.dart';

/// Everything that links the assistant to the outside: the MCP servers live in
/// the agent's config (each adds a set of tools — a database, a design tool, a
/// search provider), and under them the catalog services a future sign-in will
/// connect in one step.
///
/// Laid out as cards rather than rows, and the description is the reason. Thirty
/// unfamiliar service names in a column answer "what is installed"; somebody
/// opening this screen is asking "what do I get if I connect this", and only the
/// blurb answers that. The row form had nowhere to put it — a paragraph
/// truncated into a 20px line, ten of them stacked, reads as a wall — so it was
/// moved to a dialog nobody opened. A card has the room.
class ConnectorList extends StatelessWidget {
  const ConnectorList({
    super.key,
    required this.connectors,
    this.filtered = false,
    this.searching = false,
    this.showingConnected = false,
    this.onReachedEnd,
    this.footer,
  });

  final List<Connector> connectors;

  /// A search or a status pill is narrowing the list, so an empty [connectors]
  /// means "nothing matched" — not "nothing configured".
  final bool filtered;

  /// The Connected pill is selected, so an empty [connectors] means "you have
  /// not connected anything" — not "nothing matched".
  ///
  /// Needed because [filtered] is true here by construction: selecting the pill
  /// *is* a narrowing, so without this a fresh machine opening Connected is told
  /// "No connectors match that search" about a search nobody ran.
  final bool showingConnected;

  /// A directory search is in flight, so an empty [connectors] means "not yet"
  /// rather than "nothing matched".
  ///
  /// **Without this the screen accuses the search of failing before it has
  /// run.** `search()` clears the rows and sets `loading` in the same breath, so
  /// between the keystroke and the registry's answer the list is genuinely
  /// empty — and said so, in as many words, until the results arrived and
  /// replaced it. Whichever way the search ends, the user saw "No matches"
  /// first.
  final bool searching;

  /// Fetch the directory's next page — the scroll is near the bottom.
  final VoidCallback? onReachedEnd;

  /// The directory's tail, drawn after the last card *inside* the scroll view.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    if (connectors.isEmpty) {
      // Checked before either verdict: both of them state a result, and there
      // is no result yet.
      if (searching) return const _SearchingGrid();
      // Before the `filtered` verdict, which would otherwise claim a search
      // came back empty on a screen where nobody searched.
      if (showingConnected) return const _NothingConnected();
      return filtered
          ? const EmptyState.noMatches(
              message: 'No connectors match that search.',
            )
          : const _Empty();
    }
    final sections = sectionExtensionItems(
      items: connectors,
      sectionOf: (c) => c.connected ? 'Connected' : 'Available',
      leading: const ['Connected', 'Available'],
      filtered: filtered,
    );
    return ExtensionGrid(
      sections: sections,
      onReachedEnd: onReachedEnd,
      footer: footer,
      cardBuilder: (context, connector) => switch (connector.server) {
        final McpServer server => _McpCard(
          server: server,
          imageUrl: connector.imageUrl,
          connector: connector,
        ),
        null => _CatalogCard(connector: connector),
      },
    );
  }
}

/// The shape every connector card shares: a mark and a name across the top with
/// the action in the corner, and a body line under it.
///
/// One widget rather than two similar layouts, so a card for a service you have
/// not connected and a card for one you have line up on the same grid — the mark
/// at the same offset, the name on the same baseline, the action in the same
/// corner. Two hand-written copies drift the first time only one is edited, and
/// on a wall of cards that drift is visible in a way it never was in a column.
class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.imageUrl,
    required this.fallbackIcon,
    required this.name,
    required this.actions,
    this.tag,
    this.popularity,
    this.note = '',
    this.blurb = '',
    this.onTap,
  });

  final String imageUrl;
  final IconData fallbackIcon;
  final String name;

  /// The card's control cluster, in the top-right corner.
  final Widget actions;

  /// One tag beside the name, when the card has something to state.
  final Widget? tag;

  /// How much this service is used, for a row from the public directory.
  ///
  /// Sits at the end of the name row rather than in [tag]: a tag states what
  /// *this install* did — signed in, waiting — while this is a fact about the
  /// service, and a connected directory row can honestly show both.
  final Widget? popularity;

  /// What just happened to this connector, when something did.
  final String note;

  /// What the service gives you. Shown when there is no [note].
  final String blurb;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    // The note replaces the blurb rather than joining it. The card is a fixed
    // height and can hold one paragraph, and the moment there is a note it is
    // what the user is looking for — "sign-in cancelled", "not on this
    // computer". The blurb will still be there next time; the note will not.
    final hasNote = note.isNotEmpty;
    return ExtensionTileSurface(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A link, not a cloud. Every card here is a connector whether or
              // not the backend published a logo, and a cloud reads as
              // "somewhere remote" — the one thing already obvious.
              ConnectorMark(imageUrl: imageUrl, fallbackIcon: fallbackIcon),
              const SizedBox(width: 10),
              // Nudged down so the name sits on the mark's optical centre
              // rather than its top edge.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (tag != null) ...[const SizedBox(width: 6), tag!],
                      if (popularity != null) ...[
                        const SizedBox(width: 8),
                        popularity!,
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              actions,
            ],
          ),
          const SizedBox(height: 9),
          // Expanded, not sized: the grid fixes the card's height, so the body
          // takes whatever is left and clamps itself. Two lines is what fits at
          // the default text size and what the clamp keeps it to at any other —
          // an overflow here would paint outside the card, over its neighbour.
          Expanded(
            child: Text(
              hasNote ? note : blurb,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                // A note earns the stronger ink: it is about *this attempt*,
                // while the blurb is standing copy that reads the same on every
                // card and should stay quiet.
                color: hasNote
                    ? AppPalette.textPrimary
                    : AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a card says under the name.
///
/// The catalog's blurb first — it answers "what do I get if I connect this?",
/// which is the question a wall of unfamiliar names raises. A hand-configured
/// server has no blurb, and for that one the address or command line *is* the
/// description: it is the only thing that tells two of them apart.
String _cardBlurb(Connector connector) {
  final blurb = connector.catalogEntry?.description ?? '';
  if (blurb.isNotEmpty) return blurb;
  if (connector.description.isNotEmpty) return connector.description;
  // **Says the absence rather than leaving one.** 14% of the public directory
  // ships no description at all — measured over 300 rows, and concentrated in
  // six publishers, one of which accounts for 19 of them. There is nowhere else
  // to look: the registry has no per-server endpoint (every path shape 404s), so
  // the blurb is missing at the source.
  //
  // A blank half-card reads as a row that failed to load, which is the one thing
  // it is not. Naming the author keeps the sentence honest — this is something
  // they did not write, not something the app could not fetch.
  return connector.catalogEntry != null
      ? 'No description — the author of this server did not write one.'
      : '';
}

/// A catalog service: its mark, its name, what it gives you, and whatever action
/// its state allows.
///
/// Tapping anywhere but the action opens the detail, which holds the full blurb
/// this card clamps to two lines.
class _CatalogCard extends ConsumerWidget {
  const _CatalogCard({required this.connector});

  final Connector connector;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(connectorLinkControllerProvider);
    // A line the card owns: what this connector is waiting for, or how its last
    // attempt ended.
    final note = link.messageFor(connector.id).isNotEmpty
        ? link.messageFor(connector.id)
        : connector.needsSignInHere
        // Says the two facts it has — the account authorized this, this
        // computer has no credential — and nothing about why. The old line
        // claimed "on another computer", which is a guess, and a wrong one
        // whenever the gateway has renamed the connector out from under a
        // stored token (see Connector.needsSignInHere).
        ? 'Connected to your account, but not on this computer.'
        // Signed in, and the gateway has no tools behind it yet. Said here or
        // nowhere: the tag reports only whether a credential is held.
        : connector.connectedButUnusable
        ? "Signed in. The agent can't use it yet — tools are coming."
        : !connector.canConnect && connector.catalogEntry != null
        ? _unavailableReason(connector)
        : '';

    return _CardShell(
      imageUrl: connector.imageUrl,
      fallbackIcon: Icons.link_rounded,
      name: connector.name,
      // One tag, answering one question: does the app hold a credential for
      // this? Whether the gateway has wired up tools yet is a different
      // question, and the note is where that belongs.
      tag: connector.token != null
          ? const ExtensionTag(label: 'Signed in')
          : null,
      note: note,
      // **Dropped while a sign-in is pending**, because the name row cannot
      // afford all three. Measured at a 320px card: with the star present, a
      // spinner and a Cancel button leave the name 53px — "Instagram" and
      // "Google Sheets" both render as an ellipsis, and at 260px the name is
      // squeezed to nothing at all. The star is standing information that will
      // be back the moment this resolves; the name is how the user knows which
      // card is asking them to finish in the browser.
      popularity: link.isPending(connector.id) ? null : _UseCount.of(connector),
      blurb: _cardBlurb(connector),
      actions: ConnectorAction(connector: connector),
      onTap: () => showConnectorDetailsDialog(
        context,
        connector,
        actionBuilder: (close) => ConnectorAction(
          connector: connector,
          onSettled: close,
          labelled: true,
        ),
      ),
    );
  }
}

/// How much a directory service is used, as a star and a rounded number.
///
/// **The public registry's only quality signal that is a number.** On a list
/// anyone can publish to, `useCount` is what separates a service people rely on
/// from a weekend experiment — measured across one page it spans 0 to 76,715, so
/// it separates a great deal.
///
/// Drawn only for a row that has one. Gateway rows, hand-typed servers and any
/// directory entry the registry reports as unused all leave it off rather than
/// showing a zero: "★ 0" reads as a verdict, and absence reads as "not
/// applicable", which is what it is.
class _UseCount extends StatelessWidget {
  const _UseCount({required this.count});

  final int count;

  /// The badge for [connector], or null when there is no number to show.
  static Widget? of(Connector connector) {
    final count = connector.catalogEntry?.useCount ?? 0;
    return count > 0 ? _UseCount(count: count) : null;
  }

  /// `76715` → `76.7k`. Four digits of precision on a card this size is four
  /// digits nobody compares; the magnitude is the whole message.
  static String format(int count) {
    if (count < 1000) return '$count';
    final thousands = count / 1000;
    if (thousands < 10) return '${thousands.toStringAsFixed(1)}k';
    if (count < 1000000) return '${thousands.round()}k';
    return '${(count / 1000000).toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Gold, from `AppPalette.warn` rather than a literal: it resolves per
        // brightness (#FFB020 dark, #B45309 light), so the star stays legible on
        // a white card instead of glaring off it.
        Icon(Icons.star_rounded, size: 13, color: AppPalette.warn),
        const SizedBox(width: 2),
        Text(
          format(count),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: AppPalette.textFaint,
          ),
        ),
      ],
    );
  }
}

/// The Connect / Cancel / Remove control, and the work behind it.
///
/// Owns its own busy flag and both handlers so the row and the detail dialog can
/// each just place one of these. Reusing the widget rather than the two callbacks
/// is what keeps the confirm wording, the toast rules and the spinner identical
/// in both places — a second copy of this logic would drift the first time only
/// one of them was edited.
class ConnectorAction extends ConsumerStatefulWidget {
  const ConnectorAction({
    super.key,
    required this.connector,
    this.onSettled,
    this.labelled = false,
  });

  final Connector connector;

  /// Spell the action out instead of drawing it as `+` / `✕`.
  ///
  /// For the detail dialog, which already carries its own `✕` to dismiss itself.
  /// Two identical glyphs a few pixels apart meant "close this" and "throw the
  /// credential away", and nothing on screen said which was which — the worse
  /// of the two being irreversible. A card cannot afford the words (they crowd
  /// out a long service name), a dialog can.

  /// Called once a connect or disconnect has actually landed.
  ///
  /// Exists for the detail dialog, which closes itself here. It has to: the
  /// dialog is handed a [Connector] *value*, a snapshot taken when it opened, so
  /// after a sign-in it would go on reporting "Not connected" beside a Connect
  /// button that had already worked. Rebuilding it from a provider instead would
  /// be the other fix, and a worse one — the row it was opened from can vanish
  /// into a different section, leaving the dialog watching nothing.
  ///
  /// The row passes nothing. A `Navigator.pop` from there would close the
  /// settings page.
  final VoidCallback? onSettled;

  final bool labelled;

  @override
  ConsumerState<ConnectorAction> createState() => _ConnectorActionState();
}

class _ConnectorActionState extends ConsumerState<ConnectorAction> {
  bool _busy = false;

  Future<void> _connect() async {
    final toast = ToastScope.of(context);
    final name = widget.connector.name;
    final entry = widget.connector.catalogEntry;
    setState(() => _busy = true);
    final notifier = ref.read(connectorLinkControllerProvider.notifier);
    // `connectCatalog` is what picks the route — through the gateway, or
    // register-and-authorize against the provider itself. The fallback is for a
    // row with no catalog entry behind it, which today cannot show this button
    // at all (`canConnect` reads the entry), and would otherwise turn a future
    // change there into a crash rather than the old behaviour.
    final (outcome, problem) = entry == null
        ? await notifier.connect(widget.connector.id)
        : await notifier.connectCatalog(entry);
    // Only the *widget's* work is gated on still existing. The toast is not:
    // it belongs to the screen, [toast] was captured before the await, and
    // `ToastScope.of` resolves through a static host that outlives any row.
    //
    // This row is disposed on the way through, every single time. `connect`
    // clears the old credential first, which publishes, which invalidates
    // `connectorCatalogProvider`; `connectorsProvider` awaits that catalog, so
    // it goes to `AsyncLoading` and `connectors_view.dart:90` swaps the whole
    // list for `ExtensionLoadingRows`. All of that happens *before* the browser
    // opens, and the user then spends half a minute signing in. Returning early
    // on `!mounted` therefore threw away every outcome — success, cancel and
    // both failures — which is exactly what it looked like from the outside:
    // no toast ever, for anything.
    //
    // `_disconnect` below has always had this right; this method had drifted.
    if (mounted) setState(() => _busy = false);

    switch (outcome) {
      case ConnectorLinkOutcome.connected:
        // The controller may have left a note — the usual one being that the
        // gateway has no tools behind this connector yet. Shown here instead of
        // a plain success, because "connected" alone would be a promise the row
        // then quietly walks back.
        final note = ref
            .read(connectorLinkControllerProvider)
            .messageFor(widget.connector.id);
        toast?.show(
          note.isEmpty
              ? ToastSpec(
                  message: '$name is connected.',
                  severity: ToastSeverity.success,
                )
              : ToastSpec(message: note, severity: ToastSeverity.warning),
        );
        // Guarded, unlike the toast: `close` pops *this dialog's* route, and
        // calling it once the widget is gone would pop whatever is on top now.
        if (mounted) widget.onSettled?.call();

      case ConnectorLinkOutcome.cancelled:
        // Said out loud because the browser tab is where the user's attention
        // was: they come back to the app not knowing whether closing it undid
        // anything. It didn't, and that is the reassuring half of the sentence.
        toast?.show(
          ToastSpec(
            message: 'Sign-in cancelled — $name is unchanged.',
            severity: ToastSeverity.info,
          ),
        );

      case ConnectorLinkOutcome.notStarted:
        toast?.show(
          ToastSpec(
            message: problem ?? "Couldn't start the sign-in.",
            severity: ToastSeverity.error,
          ),
        );

      case ConnectorLinkOutcome.failed:
        // Already on the row, in the controller's own words. A toast repeating
        // it would say the same thing twice in two places.
        if (problem != null) {
          toast?.show(
            ToastSpec(message: problem, severity: ToastSeverity.error),
          );
        }
    }
  }

  /// Hand the credential back: forgotten at the gateway, then here, then removed
  /// from the agent's config by the re-projection.
  ///
  /// Confirmed first, and the wording has to be honest that this does not revoke
  /// anything at the provider — only the user can do that, in the provider's own
  /// settings.
  Future<void> _disconnect() async {
    final toast = ToastScope.of(context);
    final connector = widget.connector;
    final confirmed = await _confirmDisconnect(context, connector.name);
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .disconnect(connector.id);
    if (mounted) setState(() => _busy = false);
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
      return;
    }
    // Success is worth saying out loud, and used not to be. Disconnecting is
    // the one action here with no visible result: the row does not vanish, it
    // moves back to Available, and from a dialog the user is looking at a
    // closing sheet rather than the list. Silence read as "nothing happened".
    toast?.show(
      ToastSpec(
        message: '${connector.name} is disconnected.',
        severity: ToastSeverity.success,
      ),
    );
    // Same staleness problem in reverse: a dialog left open after a disconnect
    // would still offer Remove for a credential that is gone.
    //
    // Guarded, like the connect path: closing the dialog mid-request disposes
    // this widget, and calling `close` then would pop whatever route is now on
    // top — the settings page.
    if (mounted) widget.onSettled?.call();
  }

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(connectorLinkControllerProvider);
    return _CatalogAction(
      connector: widget.connector,
      waiting: link.isPending(widget.connector.id),
      busy: _busy,
      labelled: widget.labelled,
      onConnect: _connect,
      onCancel: () =>
          ref.read(connectorLinkControllerProvider.notifier).cancel(),
      onDisconnect: _disconnect,
    );
  }
}

/// The one control a catalog row offers, chosen by state.
class _CatalogAction extends StatelessWidget {
  const _CatalogAction({
    required this.connector,
    required this.waiting,
    required this.busy,
    required this.onConnect,
    required this.onCancel,
    required this.onDisconnect,
    this.labelled = false,
  });

  /// Spell the action out rather than draw it. See [ConnectorAction.labelled].
  final bool labelled;

  final Connector connector;

  /// This row is the one waiting on a browser right now.
  final bool waiting;

  /// A request is in flight for this row (starting the link).
  final bool busy;

  final VoidCallback onConnect;
  final VoidCallback onCancel;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.

    // While the browser is open the way out is a cancel, not a spinner alone:
    // the user may have closed the tab, and a control that only spins would
    // strand them.
    //
    // **The word, not a ✕.** This was a ✕ to keep the corner narrow, and that
    // was the wrong trade: the identical glyph, at the identical size, is
    // *Remove* on a connected card a few rows down. Two unrelated actions —
    // "stop waiting for this sign-in" and "throw away a working credential" —
    // rendered the same, and the only thing telling them apart was a tooltip
    // nobody hovers mid-sign-in. A word costs ~40px and removes the ambiguity
    // outright.
    if (waiting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // textSecondary, not textFaint: faint measures 2.90:1 on the card in
          // both themes, under the 3:1 floor a non-text element needs to be
          // seen at all.
          AppSpinner(size: SpinnerSize.small, color: AppPalette.textSecondary),
          const SizedBox(width: 6),
          _CancelButton(onPressed: onCancel),
        ],
      );
    }
    if (busy) return const AppSpinner(size: SpinnerSize.small);

    // Already signed in here: the useful action is undoing it. Offering Connect
    // again would read as the sign-in not having taken, and pressing it would
    // discard a working credential to fetch the same one.
    //
    // Quiet at rest, red on hover. In accent it competed with the add buttons
    // on every card around it, which put the loudest control on the one card
    // where nothing needs doing.
    if (connector.token != null) {
      // Spelled out in the dialog, where a bare ✕ sat beside the dialog's own ✕
      // and neither said which one discarded the credential.
      if (labelled) {
        return TextButton(
          onPressed: onDisconnect,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Disconnect'),
        );
      }
      // One control, not two. The ⓘ that used to sit here opened the detail —
      // which the whole card now does, so keeping it would put two affordances
      // for the same thing on every signed-in card.
      return AppIconButton(
        icon: Icons.close_rounded,
        size: 16,
        tooltip: 'Remove',
        destructive: true,
        onPressed: onDisconnect,
      );
    }

    // Nothing to press when the gateway can't drive this connector: the card
    // already says why, and a button that only ever fails is a worse answer
    // than no button.
    if (!connector.canConnect) return const SizedBox.shrink();

    // Same reason as Disconnect: a dialog has room for the word, and `+` beside
    // a dismiss ✕ reads as a pair of glyphs rather than the one thing to press.
    if (labelled) {
      return FilledButton(onPressed: onConnect, child: const Text('Connect'));
    }
    return _AddButton(onPressed: onConnect);
  }
}

/// The way out of a sign-in that is still waiting on the browser.
///
/// **Spelled out, and quiet.** The word is the whole point — see the note at
/// its call site for why the ✕ it replaced was ambiguous — but it is also the
/// control on a card whose primary business is happening in another window, so
/// it stays a text button rather than a filled one. Loud here would read as
/// "press this to finish", which is the opposite of what it does.
///
/// Not destructive-red either: cancelling a sign-in the user started, and may
/// have abandoned by closing the tab, is an ordinary way for this to end. Red
/// would tell them they had broken something.
class _CancelButton extends StatefulWidget {
  const _CancelButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette/AppSurface tokens.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      // The button owns its own hover. The card tracks hover too, but only to
      // reveal trailing controls — it does not tell a child the pointer is on
      // *it*, so a control that leaned on the parent's state would sit at its
      // resting colour with the cursor directly over it.
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // A fill of its own on hover, not just a colour change: this row
            // already lightens under the pointer, so colour alone could not
            // separate "on the card" from "on the button".
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            'Cancel',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              // Climbs to full colour under the pointer — an affordance that
              // stays dim while the cursor is on it reads as decoration.
              color: _hovered
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's one primary action: connect this service.
///
/// A `+` rather than the word "Connect", which is what a directory of services
/// reads as — and what the card has room for beside a name that may run long.
///
/// **Tinted at rest, not neutral.** Every other icon button in the app is quiet
/// until hovered, and that is right for a control sitting beside content it
/// shouldn't compete with. This one *is* the content: an Available card exists
/// so it can be pressed, and a grid of thirty grey `+` glyphs gives the eye
/// nothing to aim at. So it carries the accent from the start and only deepens
/// under the pointer.
class _AddButton extends StatefulWidget {
  const _AddButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppCard/AppPalette tokens.
    return Tooltip(
      message: 'Connect',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? AppCard.tint25 : AppCard.tint18,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.add_rounded,
              size: 17,
              color: AppCard.accentStrong,
            ),
          ),
        ),
      ),
    );
  }
}

/// Temporarily strip the Connected rows down to name, tag and Remove.
///
/// Hides two things at once because they are one decision: the address line
/// under the name, and the Edit button beside Remove. Half the Connected list is
/// now bridge-backed and already hides its address, so the block read as two
/// different row shapes stacked; and Edit on a signed-in row opens a form whose
/// every field is either read-only or overwritten by the next projection.
///
/// A named flag rather than deleted code: this is a look to try, not a decision
/// that the address and the editor are gone. Flip it back and both return.
/// Row tap still opens Edit for a hand-added server, so nothing becomes
/// unreachable while this is off.
const bool _kShowRowDetails = false;

class _McpCard extends ConsumerStatefulWidget {
  const _McpCard({
    required this.server,
    required this.connector,
    this.imageUrl = '',
  });

  final McpServer server;

  /// The card this server belongs to, for the one question the server itself
  /// can't answer: did the user configure this by hand, or did a sign-in write
  /// it? The two get different controls.
  final Connector connector;

  /// The catalog's mark when this server matched one; empty for a server the
  /// user configured by hand, and the card falls back to a transport glyph.
  final String imageUrl;

  @override
  ConsumerState<_McpCard> createState() => _McpCardState();
}

class _McpCardState extends ConsumerState<_McpCard> {
  bool _busy = false;

  /// This server exists because the app signed into a connector, not because
  /// the user typed a URL into the Add dialog.
  ///
  /// The test is the token, not the catalog match: a hand-configured server can
  /// share a name with a catalog entry, and only a credential in this machine's
  /// store proves the app put the entry there.
  bool get _isLinkedConnector => widget.connector.token != null;

  /// This row's server is the app's own loopback bridge, not the provider.
  ///
  /// Asked of the transport rather than of the URL, so a local MCP server the
  /// user configured by hand keeps showing its address — that one is theirs and
  /// the address is the point.
  bool get _servedByBridge {
    final token = widget.connector.token;
    return token != null &&
        effectiveTransport(token) == ConnectorTransport.rest;
  }

  /// Hand back the credential, which also clears the config entry.
  ///
  /// Deliberately the connector's disconnect rather than
  /// `mcpServersProvider.remove`: the entry is a *projection* of the stored
  /// token, so deleting the entry alone leaves the token behind and the next
  /// projection writes the row straight back.
  Future<void> _disconnect() async {
    final toast = ToastScope.of(context);
    final name = widget.connector.name;
    final confirmed = await _confirmDisconnect(context, name);
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .disconnect(widget.connector.id);
    if (mounted) setState(() => _busy = false);
    // Both outcomes, in one place — the shape `_delete` below has always had.
    // This method reported only failures, so a disconnect that worked looked
    // exactly like a click that did not register.
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : ToastSpec(
              message: '$name is disconnected.',
              severity: ToastSeverity.success,
            ),
    );
  }

  Future<void> _delete() async {
    final server = widget.server;
    // The resolved name for anything the user reads, the raw key for the write.
    // These are the same string for most servers and deliberately not for the
    // rest: `Connector.name` is the display form — a catalog label, or the
    // config key with its first letter raised — while `remove` addresses the
    // entry in `config.yaml`, which is case-sensitive and must stay verbatim.
    // Asking "Remove bigquery?" one row under a list that says `Bigquery` is the
    // small inconsistency this avoids.
    final shown = widget.connector.name;
    final confirmed = await _confirmRemove(context, shown);
    if (confirmed != true || !mounted) return;

    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(mcpServersProvider.notifier)
        .remove(server.name);
    if (mounted) setState(() => _busy = false);
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : ToastSpec(
              message: '$shown removed.',
              severity: ToastSeverity.success,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    // The catalog's blurb where there is one. Where there isn't, the address —
    // for a hand-written server that *is* the description, and the only thing
    // that tells two of them apart.
    //
    // Not gated on `_kShowRowDetails`, which hid it from the old **rows**. That
    // was a judgement about a 20px line competing with a name; a card has a
    // paragraph's worth of space under the name, and leaving it empty makes a
    // fixed-height card look broken rather than tidy. The flag still governs
    // the Edit button, which is a separate question.
    //
    // A bridge-backed connector is the exception and keeps nothing:
    // `http://127.0.0.1:61755/c/gmail/mcp` is this app's own plumbing, it
    // changes when the port does, and it says nothing about Gmail.
    final catalogBlurb = widget.connector.catalogEntry?.description ?? '';
    final blurb = catalogBlurb.isNotEmpty
        ? catalogBlurb
        : (_servedByBridge ? '' : widget.connector.description);

    return _CardShell(
      imageUrl: widget.imageUrl,
      fallbackIcon: _transportIcon(server.transport),
      // The resolved display name, not the config key. `Connector.name` is
      // already the catalog's label where there is one and the raw key where it
      // isn't, so a hand-written server is unaffected.
      name: widget.connector.name,
      // Answers "did this need an account?", not "how is it reached?". `HTTP`
      // vs `Local` was the transport — true, and never the thing anyone wanted
      // to know while looking at a list of connectors. A server needing no
      // sign-in is not lesser: it is simply open, and the tag says so plainly
      // rather than implying something is missing.
      tag: ExtensionTag(
        label: switch (server.transport) {
          McpStdio() => 'Local',
          McpHttp() => _isLinkedConnector ? 'Signed in' : 'No sign-in',
        },
      ),
      blurb: blurb,
      // Tapping a card opens whatever *is* its detail, which differs by kind. A
      // signed-in connector has a description and an account to show; a server
      // the user typed has neither, and its detail is the form they typed it
      // into — so that card opens Edit rather than a dialog with two empty
      // fields under its name.
      onTap: _isLinkedConnector
          ? () => showConnectorDetailsDialog(
              context,
              widget.connector,
              actionBuilder: (close) => ConnectorAction(
                connector: widget.connector,
                onSettled: close,
                labelled: true,
              ),
            )
          : () => showEditMcpDialog(context, server, signedIn: false),
      actions: _busy
          ? const AppSpinner(size: SpinnerSize.small)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Edit is on every card, so the controls stop looking
                // arbitrary. What it *opens* still differs, and has to: on a
                // signed-in card the dialog shows the name and hides the
                // credential fields, because the token belongs to the flow that
                // fetched it and the next projection would overwrite anything
                // typed over it.
                if (_kShowRowDetails) ...[
                  AppIconButton(
                    icon: Icons.edit_outlined,
                    size: 16,
                    tooltip: 'Edit',
                    onPressed: () => showEditMcpDialog(
                      context,
                      server,
                      signedIn: _isLinkedConnector,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                // One control, two code paths. The *action* genuinely differs —
                // a signed-in card hands the credential back through the
                // connector controller, a hand-added one only drops the config
                // entry — and they can't be merged: calling
                // `mcpServersProvider.remove` on a signed-in card would leave
                // the token behind and the entry would reappear at the next
                // projection.
                //
                // But that difference doesn't belong in the control. The card
                // already carries it (`Signed in` / `No sign-in`), and the
                // confirm dialog states the consequence in full. Saying it
                // twice bought nothing and cost the grid its evenness.
                AppIconButton(
                  icon: Icons.close_rounded,
                  size: 16,
                  tooltip: 'Remove',
                  destructive: true,
                  onPressed: _isLinkedConnector ? _disconnect : _delete,
                ),
              ],
            ),
    );
  }
}

IconData _transportIcon(McpTransport transport) => switch (transport) {
  McpStdio() => Icons.terminal_rounded,
  McpHttp() => Icons.cloud_outlined,
};

/// Removing a hand-added connector stops the assistant using its tools —
/// reversible (add it back), but worth a beat so a stray click doesn't drop one.
///
/// How wide a confirm dialog is, and the reason it is stated at all.
///
/// `AlertDialog` sizes itself to its content, and a paragraph is content with no
/// natural width — so it took the whole window, one line of prose running the
/// full span of the screen. 420 is the app's existing narrow-dialog width (the
/// chat rename, the archived-chat prompts); the 460 elsewhere is for dialogs with
/// form fields in them, which these are not.
const double _confirmWidth = 420;

/// Both confirm dialogs are deliberately the same shape, because the button that
/// opens them is now the same word: same "Remove NAME?" title, same red Remove.
/// The middle paragraph is the only part that differs, and it is the only place
/// the difference is stated — so it has to carry it plainly. Here, that there is
/// no account involved at all.
Future<bool?> _confirmRemove(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove $name?'),
      content: SizedBox(
        width: _confirmWidth,
        child: Text(
          'The assistant will stop using $name on this computer. Nothing was '
          'signed in for it, so there is no account to disconnect — you can add '
          'it back any time.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: dangerButtonStyle(),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

/// Removing a signed-in connector hands back the credential this machine holds.
///
/// The second sentence is the one that matters: this clears the token here and
/// at the gateway, and it does **not** revoke the access granted at the
/// provider. Only the user can do that, in the provider's own settings, and a
/// dialog that let them believe otherwise would leave access standing that they
/// think they withdrew.
///
/// Titled "Remove", like the button and like [_confirmRemove], so the word the
/// user pressed is the word they're asked to confirm. The account is what makes
/// this different from that one, and the paragraph says so.
Future<bool?> _confirmDisconnect(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove $name?'),
      content: SizedBox(
        width: _confirmWidth,
        child: Text(
          'The assistant will stop using $name on this computer and this Mac '
          'will forget the sign-in. Your $name account keeps whatever access '
          'you granted — revoke that in $name\'s own settings.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: dangerButtonStyle(),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

/// No servers yet — say what MCP is for, and offer the one action that fixes it.
/// Placeholder cards while a search is in flight, in place of a verdict.
///
/// Cards rather than a spinner, and cards the same shape as the real ones: what
/// is coming is a grid of connectors, and a skeleton that matches it means the
/// results replace the placeholders without the layout reflowing. A centred
/// spinner would move everything the moment it was swapped out.
///
/// Six, in three rows of two — enough to fill the pane on the window sizes this
/// screen is used at. Unlike `_DirectorySkeletonGrid`, which is bound to the
/// slack a `Flexible` list leaves it, this one *is* the pane.
class _SearchingGrid extends StatelessWidget {
  const _SearchingGrid();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SingleChildScrollView(
      // The results will scroll; a placeholder that cannot leaves the pane
      // jumping between a fixed block and a scroll view as the answer lands.
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 3; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Opacity(
                // Fading down the page says "and more below" rather than
                // ending on a hard edge — the same trick the directory's own
                // skeletons use.
                opacity: 1 - row * 0.28,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < 2; col++) ...[
                      if (col > 0) const SizedBox(width: 10),
                      const Expanded(child: _SearchingCard()),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One placeholder card, laid out like a real connector card: a 30px mark, a
/// 12px gap, the name, then two lines of blurb.
class _SearchingCard extends StatelessWidget {
  const _SearchingCard();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ExtensionTileSurface(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(
              children: [
                Skeleton(width: 30, height: 30, radius: 9),
                SizedBox(width: 12),
                Skeleton(width: 96, height: 13),
              ],
            ),
            SizedBox(height: 14),
            Skeleton(height: 11),
            SizedBox(height: 7),
            SkeletonLine(widthFactor: 0.62, height: 11),
          ],
        ),
      ),
    );
  }
}

/// The Connected pill, on a machine that has not connected anything.
///
/// Says what is true and points at the way out. Deliberately not phrased as a
/// failure: nothing is wrong, the user is simply early — so no red, no "none
/// found", and the action is the one that fixes it.
class _NothingConnected extends StatelessWidget {
  const _NothingConnected();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return const EmptyState(
      icon: Icons.link_off_rounded,
      title: 'Nothing connected yet',
      message:
          'Connectors you sign in to appear here. Browse the directory to '
          'find one.',
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.hub_outlined,
      // Reached only when the catalog is empty too — the gateway is unreachable
      // or has nothing on offer — so this can't promise a list to pick from.
      // The manual path is the one thing that still works offline.
      title: 'No connectors yet',
      message:
          'Connect one to give the assistant tools from outside — a database, '
          'a design tool, a web service.',
      action: FilledButton.icon(
        onPressed: () => showAddMcpDialog(context),
        icon: const Icon(Icons.add_rounded, size: AppControl.iconSize),
        label: const Text('Add custom connector'),
      ),
    );
  }
}

/// Why a catalog row can't be connected from here.
///
/// Both cases are real and neither is the user's doing, so the row explains
/// itself rather than leaving a dead button to be discovered by pressing it.
String _unavailableReason(Connector connector) {
  final entry = connector.catalogEntry;
  if (entry == null) return '';
  // No gateway row reaches this branch — `parseGatewayConnectors` drops every
  // `pat` connector — and no self-serve row does either, since those are always
  // `dcr`. It stays for an `auth_type` this build has never heard of, which
  // lands on `manual` and would otherwise present a row with no button and no
  // explanation.
  //
  // Named for the state rather than for `!= app`, which stopped being the same
  // question once `dcr` existed: that one *is* connectable, from here.
  if (entry.authMethod == ConnectorAuthMethod.manual) {
    return 'Needs a personal access token — not available from the app yet.';
  }
  // `mcpReady` is deliberately not tested here. It no longer gates Connect, so
  // this helper is never called for it; a connector with no tools yet is
  // connectable, and the row says so once it *is* connected.
  return '';
}
