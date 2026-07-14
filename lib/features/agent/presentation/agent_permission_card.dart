import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/agent_permissions.dart';
import '../logic/edit_diff.dart';

/// The assistant has stopped mid-answer and is asking before it touches this
/// computer: a command it wants to run, or a change it wants to make to a file.
///
/// Pinned above the composer rather than dropped into the transcript, because it
/// isn't history — it's a question holding everything up, and it must not be
/// scrollable out of sight. Nothing happens unless the user says yes; ignoring it
/// is a no ([kAgentPermissionTimeout]).
class AgentPermissionCard extends ConsumerWidget {
  const AgentPermissionCard({super.key, required this.request});

  final AgentPermission request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(agentPermissionProvider.notifier);
    final isCommand = request.kind == AgentPermissionKind.command;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppPalette.accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            icon: isCommand ? Icons.terminal_rounded : Icons.edit_note_rounded,
            title: isCommand
                ? 'Run this on your computer?'
                : 'Change this file?',
            subtitle: isCommand ? request.summary : (request.path ?? ''),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: isCommand
                    ? _Command(command: request.command ?? '')
                    : _Diff(
                        lines: buildEditDiff(
                          request.oldText,
                          request.newText ?? '',
                        ),
                      ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppPalette.divider)),
            ),
            child: Padding(
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
                        controller.answer(AgentPermissionChoice.refuse),
                    child: const Text("Don't allow"),
                  ),
                  if (request.canAllowForChat)
                    TextButton(
                      onPressed: () =>
                          controller.answer(AgentPermissionChoice.allowForChat),
                      child: const Text('Allow in this chat'),
                    ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () =>
                        controller.answer(AgentPermissionChoice.allowOnce),
                    child: const Text('Allow once'),
                  ),
                ],
              ),
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
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: SelectableText(
        command,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.45,
          color: AppPalette.textPrimary,
        ),
      ),
    );
  }
}

/// The change, line by line: what goes, what arrives.
class _Diff extends StatelessWidget {
  const _Diff({required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (final line in lines) _DiffRow(line: line)],
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final (prefix, color) = switch (line.kind) {
      DiffLineKind.added => ('+', AppPalette.online),
      DiffLineKind.removed => ('-', Theme.of(context).colorScheme.error),
      DiffLineKind.context => (' ', AppPalette.textFaint),
    };
    return Text(
      '$prefix ${line.text}',
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.5,
        color: color,
      ),
    );
  }
}

/// How long is left to answer. The agent doesn't wait forever, and a card that
/// quietly stopped working would be worse than one that says so.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.timeout, this.style});

  final Duration timeout;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
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
