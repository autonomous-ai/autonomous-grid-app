import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../agents/logic/agent_chat_scope.dart';
import '../../agents/logic/agent_questions.dart';
import '../logic/chat_sessions_controller.dart';
import 'agent_question_block.dart';

/// The card over the composer when the assistant has stopped to ask something.
///
/// **Why a card and not a menu.** Claude Code's `AskUserQuestion` draws its own
/// picker in a terminal; under `claude -p` there is no terminal, so the CLI
/// answers the call itself — *"The user did not answer the questions"* — and the
/// model guesses on. Everything it asked was still in the call, and this is the
/// app asking it where the user can actually answer. The pick goes back as the
/// next message, because by the time it is made the tool call is long closed.
///
/// It therefore never blocks: the turn runs on while the card waits, and an
/// answer given late is simply the next thing said in the conversation.
class AgentQuestionsCard extends ConsumerStatefulWidget {
  const AgentQuestionsCard({super.key});

  @override
  ConsumerState<AgentQuestionsCard> createState() => _AgentQuestionsCardState();
}

class _AgentQuestionsCardState extends ConsumerState<AgentQuestionsCard> {
  /// Question index → the labels picked for it.
  final Map<int, Set<String>> _picks = {};

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A different set of questions — a new one asked, a chat switched to — is a
    // different decision, so picks made against the old one are dropped rather
    // than sent as the answer to something else.
    ref.listen(openChatQuestionsProvider, (_, _) => setState(_picks.clear));
    final questions = ref.watch(openChatQuestionsProvider);
    if (questions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeader(onDismiss: _dismiss),
          const _DidNotWaitLine(),
          // Bounded: four questions with four explained options apiece is a
          // screenful, and this sits on top of the conversation the user is
          // reading.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, question) in questions.indexed)
                    AgentQuestionBlock(
                      question: question,
                      picked: _picks[index] ?? const {},
                      onPick: (label) => _pick(index, question, label),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              // Nothing picked is not an answer — the way past without one is
              // the composer, or the ✕.
              onPressed: _picks.values.any((s) => s.isNotEmpty)
                  ? () => _send(questions)
                  : null,
              child: Text(
                questions.length > 1 ? 'Send answers' : 'Send answer',
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _pick(int index, AgentQuestion question, String label) {
    setState(() {
      if (!question.multiSelect) {
        _picks[index] = {label};
        return;
      }
      // Tapping a chosen answer again takes it back — the only way to undo a
      // pick on a question that allows several.
      final chosen = _picks.putIfAbsent(index, () => <String>{});
      if (!chosen.remove(label)) chosen.add(label);
    });
  }

  void _send(List<AgentQuestion> questions) {
    final answer = answerToQuestions(questions, _picks);
    if (answer.isEmpty) return;
    setState(_picks.clear);
    ref.read(chatSessionsProvider.notifier).answerQuestions(answer);
  }

  void _dismiss() {
    final chatId = ref.read(agentChatScopeProvider);
    if (chatId == null) return;
    setState(_picks.clear);
    ref.read(agentQuestionsProvider.notifier).clear(chatId);
  }
}

/// What the card is, and the way out of it without answering.
class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.help_outline_rounded,
          size: 17,
          color: AppPalette.textSecondary,
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'The assistant asked you to decide',
            style: TextStyle(fontSize: 13, fontWeight: AppFont.medium),
          ),
        ),
        IconButton(
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 16),
          tooltip: 'Leave it — answer in your own words instead',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// Why the assistant is still working under a question it hasn't heard back on.
///
/// It didn't wait, and it couldn't: the call was answered by the CLI before this
/// card existed. Saying so is the difference between a turn that looks like it
/// ignored the user and one they understand — and it only appears while a turn
/// is actually running, so a settled chat isn't told about a race that is over.
class _DidNotWaitLine extends ConsumerWidget {
  const _DidNotWaitLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final sending = ref.watch(chatSessionsProvider.select((s) => s.sending));
    if (!sending) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 27, right: 8, bottom: 2),
      child: Text(
        "It carried on while you decide — your answer goes as the next message.",
        style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
      ),
    );
  }
}
