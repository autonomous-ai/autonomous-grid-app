import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/code_text_scope.dart';
import '../logic/agent_permissions.dart';
import '../logic/edit_diff.dart';
import 'diff_view.dart';

/// The assistant has stopped mid-answer and is asking before it touches this
/// computer: a command it wants to run, or a change it wants to make to a file.
///
/// Pinned above the composer rather than dropped into the transcript, because it
/// isn't history — it's a question holding everything up, and it must not be
/// scrollable out of sight. Nothing happens unless the user says yes; ignoring it
/// is a no ([kAgentPermissionTimeout]).
class AgentPermissionCard extends ConsumerWidget {
  const AgentPermissionCard({
    super.key,
    required this.chatId,
    required this.request,
  });

  /// The conversation whose agent is asking. Carried because turns run at the
  /// same time in different projects: the answer has to go back to the agent
  /// that asked, not to whichever one asked last.
  final String chatId;

  final AgentPermission request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // rebuild on theme flip — reads card/glass tokens
    final theme = Theme.of(context);
    final controller = ref.read(agentPermissionsProvider.notifier);
    final isEdit = request.kind == AgentPermissionKind.edit;
    // Icon, question and subtitle in one place, so the three can't drift apart.
    // `other` is a tool the app has no drawing for — it gets the agent's own
    // title and the raw request below, rather than a description we'd be making
    // up about something we couldn't read.
    final (icon, title, subtitle) = switch (request.kind) {
      AgentPermissionKind.command => (
        Icons.terminal_rounded,
        'Run this on your computer?',
        request.summary,
      ),
      AgentPermissionKind.edit => (
        Icons.edit_note_rounded,
        'Change this file?',
        request.path ?? '',
      ),
      AgentPermissionKind.other => (
        Icons.extension_outlined,
        'Let the assistant do this?',
        request.summary,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(icon: icon, title: title, subtitle: subtitle),
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                // Only an edit has two versions to compare; a command and an
                // unrecognised call are both "here is exactly what was asked",
                // which the monospace block already says well.
                child: isEdit
                    ? DiffView(
                        lines: buildEditDiff(
                          request.oldText,
                          request.newText ?? '',
                        ),
                      )
                    : _Command(command: request.command ?? ''),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 10, 10),
            child: Row(
              children: [
                // Flexible, so a narrow window shortens the countdown line
                // instead of pushing the buttons off the edge.
                Flexible(
                  child: _Countdown(
                    timeout: ref.watch(agentPermissionTimeoutProvider),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () =>
                      controller.answer(chatId, AgentPermissionChoice.refuse),
                  child: const Text("Don't allow"),
                ),
                if (request.canAllowForChat)
                  TextButton(
                    onPressed: () => controller.answer(
                      chatId,
                      AgentPermissionChoice.allowForChat,
                    ),
                    child: const Text('Allow in this chat'),
                  ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => controller.answer(
                    chatId,
                    AgentPermissionChoice.allowOnce,
                  ),
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppPalette.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith()),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The command, exactly as it would run — no summary, no paraphrase.
class _Command extends StatelessWidget {
  const _Command({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // rebuild on theme flip — reads palette/glass tokens
    return CodeTextScope(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: BorderRadius.circular(10),
          boxShadow: AppGlass.cardShadow,
        ),
        child: SelectableText(
          command,
          style: AppFont.codeStyle(color: AppPalette.textPrimary, height: 1.45),
        ),
      ),
    );
  }
}

/// The change, line by line: what goes, what arrives.
/// How long is left to answer. The agent doesn't wait forever, and a card that
/// quietly stopped working would be worse than one that says so.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.timeout, this.style});

  final Duration timeout;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — builder reads textFaint
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: timeout.inSeconds.toDouble(), end: 0),
      duration: timeout,
      builder: (context, seconds, _) => Text(
        'No answer in ${seconds.ceil()}s means no',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: AppPalette.textFaint),
      ),
    );
  }
}
