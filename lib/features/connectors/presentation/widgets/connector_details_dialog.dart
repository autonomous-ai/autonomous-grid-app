import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/connector.dart';
import 'connector_mark.dart';

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
/// [action] is the row's own Connect / Remove control, handed in rather than
/// rebuilt. Passing the widget keeps the confirm wording, the toasts and the
/// spinner identical in both places — and keeps this file from importing the
/// list that opens it.
Future<void> showConnectorDetailsDialog(
  BuildContext context,
  Connector connector, {
  Widget? action,
}) => showDialog<void>(
  context: context,
  builder: (_) => _DetailsDialog(connector: connector, action: action),
);

class _DetailsDialog extends StatelessWidget {
  const _DetailsDialog({required this.connector, this.action});

  final Connector connector;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // Dialog content: watch brightness so tokens re-color on a theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final token = connector.token;
    final account = connector.catalogEntry?.accountName ?? '';

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
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
              if (action != null) ...[const SizedBox(width: 12), action!],
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
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
            if (account.isNotEmpty) _Fact(label: 'Account', value: account),
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
          ],
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
        "Signed in — no tools to use yet",
        AppPalette.warn,
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
