import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/agent_browser_controller.dart';

/// The switch that decides whether the assistant may open a browser here.
///
/// It sits on the agent's own card rather than in Settings because this is the
/// screen someone is on when they wonder what the assistant can reach — and
/// because the thing it prevents (a Chrome window appearing while you type a
/// message) is alarming enough that the way to stop it has to be somewhere
/// findable, not three menus deep.
///
/// The copy says what will happen before it happens: a separate window, none of
/// your tabs, none of your logins. A switch whose consequence is only discovered
/// after flipping it is not a choice.
class AgentBrowserRow extends ConsumerWidget {
  const AgentBrowserRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final allowed = ref.watch(agentBrowserAllowedProvider);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Let it open a browser',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  allowed
                      ? 'On — Grid opens its own Chrome window when the '
                            'assistant needs one. Your tabs and logins stay out '
                            'of it.'
                      : 'Off — nothing on this computer opens a browser while '
                            'you chat.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: allowed,
            onChanged: ref.read(agentBrowserProvider).allow,
          ),
        ],
      ),
    );
  }
}
