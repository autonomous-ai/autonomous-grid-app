import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/composer_notice_bar.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_grid_support.dart';
import '../../agents/logic/agent_status.dart';
import '../logic/chat_sessions_controller.dart';

/// Says out loud when the *grid*, not the user, decided which agent answers.
///
/// The hand-over itself is silent by design — the user's pick is kept, this grid
/// just can't run it — and a silent hand-over is exactly how a different agent's
/// answers read as the chosen one behaving oddly. So the chat states the swap
/// before the first reply, in the same words the Agents screen uses.
///
/// Shows nothing at all in the ordinary case, which is every grid that can run
/// what the user picked.
class AgentHandoverBar extends ConsumerWidget {
  const AgentHandoverBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedChatAgentProvider);
    if (blocked == null) return const SizedBox.shrink();

    final answering = ref.watch(activeChatAgentProvider);
    // The stand-in may not be installed either (a computer with only Codex on
    // it, on a grid Codex can't use). Then there is no hand-over to report —
    // there's an install to do, and the notice has to say so or the chat just
    // fails on send with nothing pointing anywhere.
    final ready = ref.watch(agentInstalledProvider(answering.id));
    return ComposerNoticeBar(
      icon: Icons.swap_horiz_rounded,
      label: ready
          ? '${agentUnsupportedHere(blocked)} '
                '${answering.name} is answering here.'
          : '${agentUnsupportedHere(blocked)} '
                'Install ${answering.name} to chat on this grid.',
      actions: [
        if (!ready)
          TextButton(
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.agents),
            child: const Text('Open Agents'),
          ),
      ],
    );
  }
}

/// The one-click way out of an agent that just failed on this grid's model:
/// hand the chat to the other installed agent.
///
/// Offered beside the failure rather than in place of it — the message says what
/// went wrong, this says what to do about it. Hidden when there's no other agent
/// that could do better, because a button that swaps one failure for another is
/// worse than none.
///
/// Taking the offer clears the failure with it: the sentence was about a turn by
/// an agent that no longer answers, and left up it sat above this same button
/// now offering to switch straight back to the one that had just failed.
class SwitchAgentButton extends ConsumerWidget {
  const SwitchAgentButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alternative = ref.watch(alternativeChatAgentProvider);
    if (alternative == null) return const SizedBox.shrink();
    return TextButton(
      onPressed: () {
        ref.read(chatPrefsProvider.notifier).setChatAgent(alternative.id);
        ref.read(chatSessionsProvider.notifier).clearError();
      },
      child: Text('Use ${alternative.name}'),
    );
  }
}
