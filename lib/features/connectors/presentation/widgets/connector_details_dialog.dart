import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_dialog.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/connector.dart';
import 'connector_mark.dart';
import 'connector_tools_panel.dart';

/// What Grid knows about one connector, opened by tapping its row.
///
/// This is where the description lives. On the row it was truncated to a line,
/// and ten truncated paragraphs stacked read as a wall of grey rather than a
/// list you can scan — so the row kept the name and its state, and the prose
/// came here, where there is room for all of it.
///
/// Deliberately **not** an edit form: nothing here belongs to the user. The
/// address and the credential come from the sign-in and are rewritten whenever
/// the connection renews, so a field to type into would discard whatever was
/// typed.
///
/// Every line is written for someone who has never heard of MCP, OAuth or
/// tokens. "Access renews" rather than `expires_at`; "tools" rather than
/// "capabilities"; and where something is genuinely missing, the sentence says
/// what that means for them rather than naming the field that is null.
///
/// [actionBuilder] supplies the row's own Connect / Remove control, and is handed
/// a `close` it can call once the action lands. A builder rather than a plain
/// widget so the callback can carry *this dialog's* context: popping with the
/// caller's would work today only because the dialog happens to be the topmost
/// route on the same navigator, and stop working the day one of these opens
/// inside a nested one.
///
/// Reusing the caller's widget — rather than rebuilding the control here — is
/// what keeps the confirm wording, the toasts and the spinner identical in both
/// places, and keeps this file from importing the list that opens it.
Future<void> showConnectorDetailsDialog(
  BuildContext context,
  Connector connector, {
  Widget Function(VoidCallback close)? actionBuilder,
}) => showAppDialog<void>(
  context: context,
  builder: (_) =>
      _DetailsDialog(connector: connector, actionBuilder: actionBuilder),
);

class _DetailsDialog extends StatelessWidget {
  const _DetailsDialog({required this.connector, this.actionBuilder});

  final Connector connector;
  final Widget Function(VoidCallback close)? actionBuilder;

  @override
  Widget build(BuildContext context) {
    // Dialog content: watch brightness so tokens re-color on a theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final token = connector.token;

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      // Deliberately **not** `scrollable: true`, which is the obvious fix for a
      // dialog that grew and is the wrong one here. It wraps the content in an
      // `IntrinsicWidth`, which asks the tool list for its natural height; a
      // `ListView` cannot answer that, and the dialog dies on a `hasSize`
      // assertion before `maxHeight` is ever consulted. Measured, not reasoned
      // about — the harness threw it. The content scrolls itself instead, below.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Close sits above the name rather than beside it: the name row
          // already carries the primary action, and two buttons at its right
          // edge make the one that matters harder to find.
          Align(
            alignment: Alignment.centerRight,
            child: AppIconButton(
              icon: Icons.close,
              size: 18,
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              ConnectorMark(
                imageUrl: connector.imageUrl,
                fallbackIcon: Icons.link_rounded,
                // Larger than the row's 30: here the mark is the subject, not a
                // column to scan down.
                size: 44,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      connector.name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _StatusLine(connector: connector),
                  ],
                ),
              ),
              if (actionBuilder != null) ...[
                const SizedBox(width: 12),
                actionBuilder!(() => Navigator.of(context).pop()),
              ],
            ],
          ),
        ],
      ),
      content: SizedBox(
        // Wider than the 460 this dialog carried when it was only a paragraph
        // of prose. A tool row is a name over a one-line description, and at
        // 460 the description was the part that got clipped — the width buys
        // back roughly a dozen characters on every row, on a list of 23.
        //
        // Capped against the window rather than fixed: on a 13" MacBook
        // (1280 logical) a hard 560 leaves almost no page either side, so the
        // smaller of the two wins.
        width: math.min(560, MediaQuery.sizeOf(context).width - 120),
        // Bounded so a long description plus a full tool list cannot push the
        // dialog past a 13" screen; `AlertDialog`'s own insets take the rest.
        // The scroll view is here rather than around the whole dialog so the
        // title — the name, the state and Disconnect — stays put while the body
        // moves under it.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (connector.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      connector.description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        // Not textFaint: on this dialog's own fill (#202020 in dark)
                        // it reaches only 3.18:1, under the 4.5:1 floor for body.
                        color: AppPalette.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ),
                // The account is deliberately not shown. What the provider hands back
                // is whichever of email/name/login it happens to have — GitHub gives a
                // username, Google an address — so the row read as an arbitrary
                // identifier rather than an answer to anything the user was asking.
                // The gateway still carries `account_name`; nothing here reads it.
                if (token?.expiresAt != null)
                  const _Fact(
                    label: 'Access renews',
                    // Not the timestamp. Nobody signed in to learn a date — they
                    // want to know whether they will have to do this again, and the
                    // honest answer is no.
                    value: 'Automatically, in the background',
                  ),
                if (token != null)
                  Text(
                    'Grid looks after this connection for you — there is nothing to '
                    'set up or keep up to date.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.45,
                    ),
                  ),
                // Last, and only once connected: the question it answers ("what can
                // I do with this?") only arises after the ones above.
                if (token != null) ConnectorToolsPanel(connector: connector),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-line verdict under the name.
///
/// Three states, because two would lie. "Signed in" and "usable" are different
/// facts: a connector whose provider has no tools yet is genuinely connected and
/// genuinely unusable, and collapsing that into one badge made two accounts in
/// the identical state look different.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.connector});

  final Connector connector;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final usable = connector.token?.isUsable ?? false;
    final signedIn = connector.token != null;

    // Never red. Nothing here is broken, and a red line for a connector whose
    // provider simply hasn't shipped tools would read as the user's problem.
    final (icon, label, tint) = switch ((signedIn, usable)) {
      (true, true) => (Icons.check_circle, 'Ready to use', AppPalette.online),
      (true, false) => (
        Icons.schedule_rounded,
        'Signed in — no tools to use yet',
        AppPalette.warn,
      ),
      // Distinct from plain "Not connected", and worth the extra state: the
      // account really has authorized this, so telling someone it is not
      // connected reads as their earlier sign-in having been lost. What is true
      // is narrower — the credential is not *here*.
      _ when connector.needsSignInHere => (
        Icons.login_rounded,
        'Connected to your account — sign in on this computer',
        AppPalette.textSecondary,
      ),
      _ => (
        Icons.remove_circle_outline,
        'Not connected',
        AppPalette.textSecondary,
      ),
    };

    return Row(
      children: [
        Icon(icon, size: 14, color: tint),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// A label above its value, matching the form fields elsewhere in the app.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
