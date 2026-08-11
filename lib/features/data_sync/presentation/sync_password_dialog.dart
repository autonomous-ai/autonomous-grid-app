import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/sync_keyring.dart';
import '../logic/sync_merge.dart';

/// What the user typed for a backup: its password, and the reminder they left.
typedef SyncPasswordAnswer = ({String password, String? hint});

/// Ask for the password that locks a new backup.
///
/// Typed twice, because this is the one password in the app that nobody can
/// reset: it protects a backup nobody — not Grid, not the user — can open
/// without it, and a typo here is only discovered on the day the backup is
/// needed.
Future<SyncPasswordAnswer?> showNewBackupPasswordDialog(BuildContext context) =>
    showDialog<SyncPasswordAnswer>(
      context: context,
      builder: (context) => const _PasswordDialog(confirming: true),
    );

/// Ask for the password of a backup being restored. [hint] is what the user left
/// for themselves when they made it.
Future<SyncPasswordAnswer?> showRestorePasswordDialog(
  BuildContext context, {
  String? hint,
}) => showDialog<SyncPasswordAnswer>(
  context: context,
  builder: (context) => _PasswordDialog(confirming: false, hint: hint),
);

/// Ask before a restore writes over chats this computer already has.
///
/// The only lossy thing a restore does, so it is the only thing worth stopping
/// for — and it names the chats rather than counting them, because "3 chats
/// will be updated" isn't enough to judge whether that's fine.
Future<bool?> showRestoreConflictDialog(
  BuildContext context,
  SyncRestorePreview preview,
) {
  final shown = preview.replacedTitles.take(5).toList();
  final rest = preview.replacedTitles.length - shown.length;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      title: Text(
        preview.replaced == 1
            ? 'Update 1 chat from this backup?'
            : 'Update ${preview.replaced} chats from this backup?',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The backup has a newer version of these, so its copy will be '
              'used here:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            for (final title in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (rest > 0)
              Text(
                '…and $rest more',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            Text(
              _reassurance(preview),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Restore'),
        ),
      ],
    ),
  );
}

/// The line under the list: everything this restore will *not* touch.
String _reassurance(SyncRestorePreview preview) {
  final parts = <String>[
    if (preview.added > 0)
      '${preview.added} other ${preview.added == 1 ? 'chat' : 'chats'} '
          'will be added',
    if (preview.keptLocal > 0)
      '${preview.keptLocal} ${preview.keptLocal == 1 ? 'chat' : 'chats'} you '
          'have worked on more recently will be kept as ${preview.keptLocal == 1 ? 'it is' : 'they are'}',
  ];
  final lead = parts.isEmpty ? '' : '${parts.join(', ')}. ';
  return '${lead}Chats only on this computer are left alone, and a copy of '
      'everything is saved first.';
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.confirming, this.hint});

  /// Making a backup (two fields plus a hint) rather than opening one.
  final bool confirming;

  final String? hint;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  final _hint = TextEditingController();

  /// Errors appear on submit, never on the first keystroke — a field that
  /// reddens as you type it is a field people fight.
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    _hint.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _password.text;
    final problem = _problemWith(password);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, (
      password: password,
      hint: _hint.text.trim().isEmpty ? null : _hint.text.trim(),
    ));
  }

  String? _problemWith(String password) {
    if (password.isEmpty) return 'Enter the password.';
    if (!widget.confirming) return null;
    if (checkSyncPassword(password) == SyncPasswordVerdict.tooShort) {
      return 'Use at least $syncPasswordMinLength characters.';
    }
    if (password != _repeat.text) return "The two passwords don't match.";
    return null;
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final weak =
        widget.confirming &&
        _password.text.isNotEmpty &&
        checkSyncPassword(_password.text) == SyncPasswordVerdict.weak;
    return AlertDialog(
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppGlass.hair),
      ),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Text(
        widget.confirming ? 'Set a password for this backup' : 'Enter password',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            Text(
              widget.confirming
                  ? 'Your chats are locked with this password before they '
                        'leave this computer. Grid never receives it, so if you '
                        'forget it this backup can never be opened — not by us '
                        'either. Each backup has its own password.'
                  : 'This is the password you set when you made this backup.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
            if (!widget.confirming && (widget.hint ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Your reminder: ${widget.hint}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 14),
            LabeledField(
              label: 'Password',
              controller: _password,
              hint: widget.confirming ? 'At least 10 characters' : '',
              obscureText: true,
              autofocus: true,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _submit(),
              error: _error,
            ),
            if (widget.confirming) ...[
              const SizedBox(height: 12),
              LabeledField(
                label: 'Password again',
                controller: _repeat,
                hint: '',
                obscureText: true,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              LabeledField(
                label: 'Reminder (optional)',
                controller: _hint,
                hint: 'Something only you would understand',
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text(
                'The reminder is stored unlocked — anyone who can see your '
                'backups can read it. Keep it oblique.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              if (weak) ...[
                const SizedBox(height: 10),
                Text(
                  'That password is a common shape and would fall quickly to '
                  'someone guessing offline. Four unrelated words work better.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirming ? 'Back up' : 'Restore'),
        ),
      ],
    );
  }
}
