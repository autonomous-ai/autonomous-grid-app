import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../logic/agent_catalog.dart';
import '../logic/agent_chat_surface.dart';

/// How chats with this agent are drawn: as messages, or as the agent's own
/// command-line program.
///
/// On the agent's card rather than in Appearance because the answer is *per
/// agent* — Claude Code and Codex open in their own program, Hermes has none to
/// open — and a setting whose meaning changes per agent belongs beside the agent
/// it is set for. It is also the screen someone is on when they wonder why one
/// assistant looks nothing like the other.
///
/// Drawn only for an agent that has both surfaces to offer
/// ([AgentTool.hasInteractiveCli]) and only while it is the one answering, which
/// is the same rule the browser row follows: the card is a tap target for
/// switching agents, and a control on a card you would tap is a control you hit
/// by accident.
class AgentSurfaceRow extends ConsumerWidget {
  const AgentSurfaceRow({super.key, required this.tool});

  final AgentTool tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final current = ref.watch(agentChatSurfaceProvider(tool));

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How new chats look',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // Says *when* it applies, on the row itself. A chat keeps
                      // the shape it started in, so someone who switches this
                      // and reopens yesterday's chat would otherwise read the
                      // unchanged chat as the setting not working.
                      'Applies to the next chat you start. Ones already open '
                      'keep the shape they began in.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AppSegmented(
                segments: [
                  for (final surface in AgentChatSurface.values)
                    SegmentSpec(label: agentChatSurfaceLabel(surface)),
                ],
                selected: AgentChatSurface.values.indexOf(current),
                onChanged: (index) => ref
                    .read(chatPrefsProvider.notifier)
                    .setAgentSurface(tool.id, AgentChatSurface.values[index]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            agentChatSurfaceDetail(current),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
