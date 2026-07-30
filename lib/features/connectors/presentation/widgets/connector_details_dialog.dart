import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../logic/connector.dart';

/// What Grid knows about a connector the user signed into.
///
/// Opened from the ⓘ on a catalog row. Deliberately **not** an edit form: there
/// is nothing here belonging to the user. The address and the credential come
/// from the sign-in and are rewritten whenever the connection is renewed, so a
/// field to type into would discard whatever was typed. A pencil icon on this
/// would be a promise the screen can't keep.
///
/// Every line is written for someone who has never heard of MCP, OAuth or
/// tokens. "Access expires" rather than `expires_at`; "tools" rather than
/// "capabilities"; and where something is genuinely missing, the sentence says
/// what that means for them rather than naming the field that is null.
Future<void> showConnectorDetailsDialog(
  BuildContext context,
  Connector connector,
) => showDialog<void>(
  context: context,
  builder: (_) => _DetailsDialog(connector: connector),
);

class _DetailsDialog extends StatelessWidget {
  const _DetailsDialog({required this.connector});

  final Connector connector;

  @override
  Widget build(BuildContext context) {
    // Dialog content: watch brightness so tokens re-color on a theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final token = connector.token;
    final account = connector.catalogEntry?.accountName ?? '';
    final usable = connector.token?.isUsable ?? false;

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 22, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Row(
        children: [
          Expanded(
            child: Text(
              connector.name,
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
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            // The headline answer, before any detail: can the assistant use this
            // right now? That is the only thing most people opened this for.
            _Status(usable: usable),
            const SizedBox(height: 22),
            if (account.isNotEmpty) _Fact(label: 'Account', value: account),
            if (connector.description.isNotEmpty)
              _Fact(label: 'What it does', value: connector.description),
            _Fact(
              label: 'Signed in',
              value: usable
                  ? 'Yes — the assistant can use it'
                  : 'Yes, but there are no tools to use yet',
            ),
            if (token?.expiresAt != null)
              _Fact(
                label: 'Access renews',
                // Not the timestamp. Nobody signed in to learn a date — they
                // want to know whether they will have to do this again, and the
                // honest answer is no.
                value: 'Automatically, in the background',
              ),
            const SizedBox(height: 6),
            Text(
              'Grid looks after the connection for you — there is nothing to '
              'set up or keep up to date. Use Disconnect on the list to remove '
              'it from this computer.',
              style: theme.textTheme.bodySmall?.copyWith(
                // Not textFaint: on this dialog's own fill (#202020 in dark) it
                // reaches only 3.18:1, under the 4.5:1 floor for body text.
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The one-line verdict at the top.
class _Status extends StatelessWidget {
  const _Status({required this.usable});

  final bool usable;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // Green for ready, amber for signed-in-but-waiting. Never red: nothing here
    // is broken, and a red row for a connector whose provider simply hasn't
    // finished shipping tools would read as the user's problem to fix.
    final tint = usable ? AppPalette.online : AppPalette.warn;
    return Row(
      children: [
        Icon(
          usable ? Icons.check_circle : Icons.schedule_rounded,
          size: 18,
          color: tint,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            usable
                ? 'Ready to use'
                : "Signed in — the assistant can't use it yet",
            style: theme.textTheme.bodyLarge,
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
