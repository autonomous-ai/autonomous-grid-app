/// The question an agent stopped to ask, put to the person holding the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_chat_ui/grid_chat_ui.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_turn_actions.dart';

/// Asks what the computer's own card asks, in the same words, with the same
/// three answers — whichever is tapped first, here or there, is the answer.
///
/// [canAnswer] is false on a computer too old to take an answer from a phone:
/// the question is still shown, because the turn is waiting on it and the
/// person should know why, but the buttons are replaced by where to answer.
class PhonePermissionCard extends ConsumerStatefulWidget {
  const PhonePermissionCard({
    required this.chatId,
    required this.question,
    required this.canAnswer,
    super.key,
  });

  /// Which conversation is waiting.
  final String chatId;

  /// What it is waiting on.
  final MobilePermission question;

  /// Whether this computer takes an answer from the phone.
  final bool canAnswer;

  @override
  ConsumerState<PhonePermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends ConsumerState<PhonePermissionCard> {
  /// Set while an answer is on its way, so a second tap does not send a
  /// second answer to a question that is already closing.
  bool _sending = false;

  Future<void> _answer(MobilePermissionChoice choice) async {
    setState(() => _sending = true);
    final refused = await answerQuestion(
      ref,
      chatId: widget.chatId,
      questionId: widget.question.id,
      choice: choice,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (refused == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(refused)));
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final question = widget.question;
    final (:icon, question: title) = permissionHeading(switch (question.kind) {
      MobilePermissionKind.command => PermissionAsk.command,
      MobilePermissionKind.edit => PermissionAsk.edit,
      MobilePermissionKind.other => PermissionAsk.other,
    });
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        boxShadow: AppGlass.shadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading(icon: icon, title: title, summary: question.summary),
          if (question.detail case final detail?) _Code(detail),
          if (question.preview case final preview?) _Code(preview),
          const SizedBox(height: 6),
          if (widget.canAnswer) ...[
            // The computer's own card counts this down; the phone cannot see
            // the clock, so it says the rule instead of pretending to a number.
            const _Deadline(),
            _Answers(
              enabled: !_sending,
              allowForChat: question.canAllowForChat,
              onAnswer: _answer,
            ),
          ] else
            const _AnswerAtComputer(),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({
    required this.icon,
    required this.title,
    required this.summary,
  });

  final IconData icon;
  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppPalette.accentOnSurface),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              if (summary.isNotEmpty)
                Text(
                  summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Exactly what was asked — the command, the file, what it would contain.
///
/// Height-capped and scrollable: an edit can be a whole file, and a card that
/// grew to fit it would push the answers off the bottom of the screen.
class _Code extends StatelessWidget {
  const _Code(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: SingleChildScrollView(
        child: CodeTextScope(
          child: SelectableText(
            text,
            style: AppFont.codeStyle(color: AppPalette.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _Answers extends StatelessWidget {
  const _Answers({
    required this.enabled,
    required this.allowForChat,
    required this.onAnswer,
  });

  final bool enabled;
  final bool allowForChat;
  final void Function(MobilePermissionChoice choice) onAnswer;

  VoidCallback? _tap(MobilePermissionChoice choice) =>
      enabled ? () => onAnswer(choice) : null;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A Wrap, not a Row: three answers do not fit one line on a narrow phone
    // at a large text size, and a clipped "Don't allow" is the worst button
    // to lose.
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 4,
      children: [
        TextButton(
          onPressed: _tap(MobilePermissionChoice.refuse),
          child: const Text(PermissionAnswerLabels.refuse),
        ),
        if (allowForChat)
          TextButton(
            onPressed: _tap(MobilePermissionChoice.allowForChat),
            child: const Text(PermissionAnswerLabels.allowForChat),
          ),
        FilledButton(
          onPressed: _tap(MobilePermissionChoice.allowOnce),
          child: const Text(PermissionAnswerLabels.allowOnce),
        ),
      ],
    );
  }
}

class _Deadline extends StatelessWidget {
  const _Deadline();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      'No answer within a minute counts as no.',
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint),
    );
  }
}

class _AnswerAtComputer extends StatelessWidget {
  const _AnswerAtComputer();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        'Answer this in Grid on your computer. Updating Grid there lets you '
        'answer from your phone.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
      ),
    );
  }
}
