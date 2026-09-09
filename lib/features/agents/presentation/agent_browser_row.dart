import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/layouts/shell_state.dart';
import '../logic/agent_browser_controller.dart';
import 'agent_browser_access_block.dart';

/// What the assistant can reach in a browser, and the two decisions behind it.
///
/// It sits on the agent's own card rather than in Settings because this is the
/// screen someone is on when they wonder what the assistant can reach — and
/// because the thing the switch prevents (a Chrome window appearing while you
/// type a message) is alarming enough that the way to stop it has to be
/// somewhere findable, not three menus deep.
///
/// Two rows, in the order people ask about them: which browser you get now
/// ([BrowserAccessBlock]), then whether the app may open one of its own.
class AgentBrowserRow extends StatelessWidget {
  const AgentBrowserRow({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 12),
    child: Column(
      children: [BrowserAccessBlock(), SizedBox(height: 10), _WhereToChoose()],
    ),
  );
}

/// Where the choice actually lives, now that there are three of them.
///
/// A line rather than a control: the question is "which browser", and it has
/// one home (Settings ▸ Browser — verified against `shell_state.dart`, group
/// Personal). A copy of it here would be the second place to answer it, and two
/// screens asking one question is how they drift apart.
///
/// The block above still belongs on this card: it reports what *this chat's
/// next turn* would actually get, which is a fact about the agent on screen
/// rather than a setting.
class _WhereToChoose extends ConsumerWidget {
  const _WhereToChoose();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final choice = ref.watch(agentBrowserChoiceProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Browser: ${choice.label}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Which browser every assistant may use is chosen in '
                'Settings ▸ Browser.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () => ref
              .read(shellSectionProvider.notifier)
              .select(ShellSection.browser),
          child: const Text('Change'),
        ),
      ],
    );
  }
}
