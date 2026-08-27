import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../core/grid_paths.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/feedback_controller.dart';
import '../logic/feedback_diagnostics.dart';
import '../logic/feedback_draft.dart';
import '../logic/log_bundle.dart';

/// Opens the feedback form.
///
/// A dialog rather than a screen: feedback is something you have *while doing
/// something else*, and a screen would make the user leave whatever prompted it
/// — which is usually the thing they were about to describe.
Future<void> showFeedbackDialog(BuildContext context) => showAppDialog<void>(
  context: context,
  // A half-written message is easy to lose to a stray click outside; the two
  // explicit ways out are Cancel and Escape.
  barrierDismissible: false,
  builder: (_) => const _FeedbackDialog(),
);

class _FeedbackDialog extends ConsumerStatefulWidget {
  const _FeedbackDialog();

  @override
  ConsumerState<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends ConsumerState<_FeedbackDialog> {
  final _message = TextEditingController();
  FeedbackKind _kind = FeedbackKind.bug;

  /// Whether the diagnostic-log bundle rides along. On by default — a report
  /// with the logs is worth far more, and most people leave a default be — but
  /// *shown*, and readable in full before the send, because these logs carry
  /// file paths and command output, not just a version string.
  final bool _attachLogs = true;

  /// What's wrong with the message, once the user has pressed Send. Null until
  /// then: a field that reddens on the first keystroke is a field people fight.
  String? _problem;

  @override
  void initState() {
    super.initState();
    // A failure from a previous open belongs to that attempt. Cleared after the
    // frame — mutating a provider during a build is a side effect in `build()`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(feedbackControllerProvider.notifier).reset();
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  bool get _hasMessage => _message.text.trim().isNotEmpty;

  Future<void> _send() async {
    // Gather the machine snapshot before building the draft. `.future` (not the
    // cached `.value`) so a send in the first fraction of a second after open —
    // before the log tail has been read — still carries the diagnostics rather
    // than racing them.
    final diagnostics = await ref.read(feedbackDiagnosticsProvider.future);
    // Only zip the logs when the switch is on — building the bundle at all is
    // gated on consent, not just its attachment.
    final bundle = _attachLogs
        ? await ref.read(feedbackLogBundleProvider.future)
        : null;
    if (!mounted) return;
    final draft = FeedbackDraft(
      kind: _kind,
      message: _message.text,
      email: ref.read(sessionProvider).userEmail,
      diagnostics: diagnostics,
    );
    final problem = draft.problem;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() => _problem = null);

    final sent = await ref
        .read(feedbackControllerProvider.notifier)
        .send(draft, logsZip: bundle?.zip);
    if (!mounted || !sent) return;
    Navigator.of(context).pop();
    ToastScope.show(
      context,
      const ToastSpec(
        message: 'Thanks — your feedback is on its way to us.',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dialog content reads colour tokens from a global the element tree can't
    // track — watch the brightness so it re-tints on a theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final send = ref.watch(feedbackControllerProvider);
    final sending = send is FeedbackSending;
    final session = ref.watch(sessionProvider);

    return AlertDialog(
      // No `backgroundColor` here on purpose: `dialogTheme` already fills a
      // dialog with the raised menu surface. Overriding it with `windowBg` — the
      // *page* colour, darker than the panels it sits over — is what made five
      // other dialogs sink into the window in dark mode.
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Send feedback',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'It goes straight to the people building Grid.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              const FieldLabel('What is this about?'),
              AppSegmented(
                // A form field, not a toolbar tab strip: the three choices
                // split the dialog's width so the control's edges line up with
                // the message box under it.
                expand: true,
                segments: [
                  for (final kind in FeedbackKind.values)
                    SegmentSpec(label: kind.label),
                ],
                selected: FeedbackKind.values.indexOf(_kind),
                // Switching kinds swaps the placeholder question, which is what
                // makes the field ask for the right thing instead of staring
                // back blankly.
                onChanged: sending
                    ? (_) {}
                    : (index) =>
                          setState(() => _kind = FeedbackKind.values[index]),
              ),
              const SizedBox(height: 20),
              LabeledField(
                label: 'Tell us more',
                controller: _message,
                hint: _kind.hint,
                fill: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
                enabled: !sending,
                autofocus: true,
                minLines: 5,
                maxLines: 10,
                error: _problem,
                // Rebuilds on every keystroke: the Send button is gated on the
                // field being non-empty, and it also clears the error the
                // moment the user acts on it rather than leaving it red until
                // the next press of Send.
                onChanged: (_) => setState(() => _problem = null),
              ),
              const SizedBox(height: 20),
              if (send is FeedbackFailed) ...[
                const SizedBox(height: 16),
                ErrorBox(message: _failureText(send)),
              ],
              const SizedBox(height: 16),
              _ReplyNote(
                email: session.userEmail,
                signedIn: session.isLoggedIn,
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: sending || !session.isLoggedIn || !_hasMessage
              ? null
              : _send,
          child: sending
              ? const AppSpinner.onAccent(size: SpinnerSize.small)
              : Text(send is FeedbackFailed ? 'Try again' : 'Send feedback'),
        ),
      ],
    );
  }
}

/// The failure line: what went wrong, then where the message was kept.
///
/// The second half matters more than it looks. A send that fails silently
/// discards something the user sat down and wrote; saying where the copy landed
/// is what makes "try again later" a real option rather than a hope. When even
/// the copy failed, it says so — that is the one case where closing the dialog
/// really does lose the text.
String _failureText(FeedbackFailed failure) {
  final path = failure.savedPath;
  if (path == null) {
    return '${failure.message}\n\nNothing has been sent yet, and we could not '
        'keep a copy on this computer — keep this window open, or copy your '
        'message somewhere safe before closing it.';
  }
  return '${failure.message}\n\nYour message is saved at ${_short(path)}, so '
      'nothing is lost.';
}

/// `/Users/x/.grid/feedback/…` → `~/.grid/feedback/…`, the way a person refers
/// to their own home.
String _short(String path) {
  final home = GridPaths.userHome;
  return path.startsWith(home) ? '~${path.substring(home.length)}' : path;
}

/// Who the reply goes to — or why nothing can be sent yet.
///
/// Shown rather than asked: the address is already the signed-in account's, and
/// a second email field would be a question the app can answer itself. Signed
/// out there is no bearer to send with at all, so this says that plainly and
/// the Send button is off — rather than letting a press fail into an error the
/// user then has to interpret.
class _ReplyNote extends StatelessWidget {
  const _ReplyNote({required this.email, required this.signedIn});

  final String? email;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.mail_outline_rounded, size: 15, color: AppPalette.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            !signedIn
                ? "You're signed out — sign in to send feedback."
                : email == null
                ? "We'll read it, though this account has no email to reply to."
                : 'If we need to ask you something, we’ll write to $email.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
