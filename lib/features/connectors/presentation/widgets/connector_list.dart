import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../shared/widgets/extension_list.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../agents/logic/mcp_server.dart';
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
class ConnectorList extends StatelessWidget {
  const ConnectorList({
    super.key,
    required this.connectors,
    this.filtered = false,
  });

  final List<Connector> connectors;

  /// A search or a status pill is narrowing the list, so an empty [connectors]
  /// means "nothing matched" — not "nothing configured".
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (connectors.isEmpty) {
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
    return ExtensionList(
      sections: sections,
      rowBuilder: (context, connector) => switch (connector.server) {
        final McpServer server => _McpRow(
          server: server,
          imageUrl: connector.imageUrl,
          connector: connector,
        ),
        null => _CatalogRow(connector: connector),
      },
    );
  }
}

/// A catalog service: its mark, its name, and whatever action its state allows.
///
/// The row is deliberately one line of text. The gateway's blurb runs to a
/// paragraph and, truncated to a row, ten of them stacked read as a wall rather
/// than a list — so the description moved to the detail dialog, which has room
/// for all of it. What stays on the row is the *state* note, because that is the
/// one line a user scanning the list needs.
///
/// Tapping anywhere but the button opens that detail.
class _CatalogRow extends ConsumerWidget {
  const _CatalogRow({required this.connector});

  final Connector connector;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    final link = ref.watch(connectorLinkControllerProvider);
    // A line the row owns: what this connector is waiting for, or how its last
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

    return ExtensionTileSurface(
      onTap: () => showConnectorDetailsDialog(
        context,
        connector,
        actionBuilder: (close) =>
            ConnectorAction(connector: connector, onSettled: close),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A link, not a cloud. Every row here is a connector whether or not
          // the backend published a logo, and a cloud reads as "somewhere
          // remote" — the one thing already obvious.
          ConnectorMark(
            imageUrl: connector.imageUrl,
            fallbackIcon: Icons.link_rounded,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        connector.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(),
                      ),
                    ),
                    // One tag, answering one question: does the app hold a
                    // credential for this? Whether the gateway has wired up
                    // tools yet is a different question, and the note below is
                    // where that belongs.
                    if (connector.token != null) ...[
                      const SizedBox(width: 8),
                      const ExtensionTag(label: 'Signed in'),
                    ],
                  ],
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConnectorAction(connector: connector),
        ],
      ),
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
  const ConnectorAction({super.key, required this.connector, this.onSettled});

  final Connector connector;

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

  @override
  ConsumerState<ConnectorAction> createState() => _ConnectorActionState();
}

class _ConnectorActionState extends ConsumerState<ConnectorAction> {
  bool _busy = false;

  Future<void> _connect() async {
    final toast = ToastScope.of(context);
    final name = widget.connector.name;
    setState(() => _busy = true);
    final (outcome, problem) = await ref
        .read(connectorLinkControllerProvider.notifier)
        .connect(widget.connector.id);
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
  });

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

    // While the browser is open the way out is Cancel, not a spinner: the user
    // may have closed the tab, and a control that only spins would strand them.
    //
    // The spinner is small and muted so Cancel is the one thing drawing the eye.
    // At the default size in accent both read as controls, and the row offers
    // two things to look at when only one of them can be pressed.
    if (waiting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // textSecondary, not textFaint: faint measures 2.90:1 on the row in
          // both themes, under the 3:1 floor a non-text element needs to be
          // seen at all. Secondary clears it and still sits below Cancel.
          AppSpinner(size: SpinnerSize.small, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      );
    }
    if (busy) return const AppSpinner(size: SpinnerSize.small);

    // Already signed in here: the useful action is undoing it. Offering Connect
    // again would read as the sign-in not having taken, and pressing it would
    // discard a working credential to fetch the same one.
    //
    // Quiet at rest, red on hover. In accent it competed with the Connect
    // buttons on every row around it, which put the loudest control on the one
    // row where nothing needs doing.
    if (connector.token != null) {
      // One control, not two. The ⓘ that used to sit here opened the detail —
      // which the whole row now does, so keeping it would put two affordances
      // for the same thing on every signed-in row.
      return _RemoveButton(onPressed: onDisconnect);
    }

    // Nothing to press when the gateway can't drive this connector: the row
    // already says why, and a button that only ever fails is a worse answer
    // than no button.
    if (!connector.canConnect) return const SizedBox.shrink();

    return FilledButton(onPressed: onConnect, child: const Text('Connect'));
  }
}

class _McpRow extends ConsumerStatefulWidget {
  const _McpRow({
    required this.server,
    required this.connector,
    this.imageUrl = '',
  });

  final McpServer server;

  /// The row this server belongs to, for the one question the server itself
  /// can't answer: did the user configure this by hand, or did a sign-in write
  /// it? The two get different controls.
  final Connector connector;

  /// The catalog's mark when this server matched one; empty for a server the
  /// user configured by hand, and the row falls back to a transport glyph.
  final String imageUrl;

  @override
  ConsumerState<_McpRow> createState() => _McpRowState();
}

class _McpRowState extends ConsumerState<_McpRow> {
  bool _busy = false;

  /// This server exists because the app signed into a connector, not because
  /// the user typed a URL into the Add dialog.
  ///
  /// The test is the token, not the catalog match: a hand-configured server can
  /// share a name with a catalog entry, and only a credential in this machine's
  /// store proves the app put the entry there.
  bool get _isLinkedConnector => widget.connector.token != null;

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
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  Future<void> _delete() async {
    final server = widget.server;
    final confirmed = await _confirmRemove(context, server.name);
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
              message: '${server.name} removed.',
              severity: ToastSeverity.success,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final server = widget.server;
    return ExtensionTileSurface(
      // Tapping a row opens whatever *is* its detail, which differs by kind. A
      // signed-in connector has a description and an account to show; a server
      // the user typed has neither, and its detail is the form they typed it
      // into — so that row opens Edit rather than a dialog with two empty
      // fields under its name.
      onTap: _isLinkedConnector
          ? () => showConnectorDetailsDialog(
              context,
              widget.connector,
              actionBuilder: (close) => ConnectorAction(
                connector: widget.connector,
                onSettled: close,
              ),
            )
          : () => showEditMcpDialog(context, server, signedIn: false),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConnectorMark(
            imageUrl: widget.imageUrl,
            fallbackIcon: _transportIcon(server.transport),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _McpInfo(server: server, signedIn: _isLinkedConnector),
          ),
          const SizedBox(width: 8),
          if (_busy)
            const AppSpinner(size: SpinnerSize.small)
          else ...[
            // Edit is on every row, so the controls stop looking arbitrary. What
            // it *opens* still differs, and has to: on a signed-in row the
            // dialog shows the name and hides the credential fields, because the
            // token belongs to the flow that fetched it and the next projection
            // would overwrite anything typed over it.
            AppIconButton(
              icon: Icons.edit_outlined,
              size: 18,
              tooltip: 'Edit',
              onPressed: () => showEditMcpDialog(
                context,
                server,
                signedIn: _isLinkedConnector,
              ),
            ),
            const SizedBox(width: 2),
            // One word, two code paths. The *action* genuinely differs — a
            // signed-in row hands the credential back through the connector
            // controller, a hand-added one only drops the config entry — and
            // they can't be merged: calling `mcpServersProvider.remove` on a
            // signed-in row would leave the token behind and the entry would
            // reappear at the next projection.
            //
            // But that difference doesn't belong in the button's *label*. The
            // row already carries it (`Signed in` / `No sign-in`), and the
            // confirm dialog states the consequence in full. Naming it twice
            // bought nothing and cost the list its evenness.
            _RemoveButton(
              onPressed: _isLinkedConnector ? _disconnect : _delete,
            ),
          ],
        ],
      ),
    );
  }
}

/// The server's name, a tag for how it's reached, and the command or URL under
/// it so the user can tell two servers apart at a glance.
class _McpInfo extends StatelessWidget {
  const _McpInfo({required this.server, this.signedIn = false});

  final McpServer server;

  /// Whether the app holds an OAuth credential for this server.
  ///
  /// Drives the tag, and since the rows all wear the same Remove button the tag
  /// is now the *only* thing that says an account is involved — so it carries
  /// the fact on its own rather than as a gloss on which control appeared. It
  /// answers "did this need a login?", which is also what decides whether
  /// removing it hands a credential back.
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip: reads AppPalette tokens
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                server.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(),
              ),
            ),
            const SizedBox(width: 8),
            // Answers "did this need an account?", not "how is it reached?".
            // `HTTP` vs `Local` was the transport — true, and never the thing
            // anyone wanted to know while looking at a list of connectors.
            // A server needing no sign-in is not lesser: it is simply open, and
            // the tag says so plainly rather than implying something is missing.
            ExtensionTag(
              label: switch (server.transport) {
                McpStdio() => 'Local',
                McpHttp() => signedIn ? 'Signed in' : 'No sign-in',
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        // One line, like the plugin and skill rows — a stdio server's command
        // line with its args is long, and wrapping it to two made the MCP rows
        // taller than everything else in the app.
        Tooltip(
          message: mcpServerSummary(server),
          waitDuration: const Duration(milliseconds: 600),
          child: Text(
            mcpServerSummary(server),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
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

/// The row's undo: quiet at rest, red under the pointer.
///
/// The text twin of `AppIconButton(destructive: true)` — same neutral resting
/// ink, same hover fill, same danger red, and the same reason for each. A word
/// rather than a glyph because this is not a ✕: it stops the agent using a
/// service, and a bare icon would leave the user guessing which.
///
/// Every row in the Connected block uses this, and every one of them says
/// **Remove**. The rows do not all *do* the same thing — a signed-in row hands
/// back a credential, a hand-added one forgets a URL — but the row already says
/// which it is (`Signed in` / `No sign-in`), and the confirm dialog spells out
/// the consequence. What it looked like instead was four rows wearing a word and
/// one wearing a trash can, which reads as the odd row being a different
/// *category* of thing rather than the same action on a row without a login.
///
/// It owns its own hover. The row underneath already lightens on hover and
/// says nothing to its children about where the pointer is, so a button
/// without its own [MouseRegion] would sit at rest the whole time it's
/// hovered — a bug this app has shipped twice.
class _RemoveButton extends StatefulWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _hovered = false;

  /// Lifted from `AppIconButton`, where it was measured: `colorScheme.error` is
  /// 3.33:1 on the dark hover fill, under the 4.5 floor, so dark gets a lighter
  /// tint of the same hue. Light's own error token already clears it.
  static const Color _dangerDark = Color(0xFFFF8A80);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette/AppSurface tokens.
    final danger = AppTheme.pick(
      Theme.of(context).colorScheme.error,
      _dangerDark,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            // Its own fill, so "on the button" is distinguishable from "on the
            // row" — the row lifts too, and colour alone wouldn't separate them.
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            'Remove',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              // Neutral at rest: a column of red buttons doing nothing reads as
              // an error state rather than a list of connected services.
              color: _hovered ? danger : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
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
  // `pat` connector. It stays for the bundled asset, which carries no auth type
  // and would otherwise present a row the app can't actually set up.
  if (entry.authMethod != ConnectorAuthMethod.app) {
    return 'Needs a personal access token — not available from the app yet.';
  }
  // `mcpReady` is deliberately not tested here. It no longer gates Connect, so
  // this helper is never called for it; a connector with no tools yet is
  // connectable, and the row says so once it *is* connected.
  return '';
}
