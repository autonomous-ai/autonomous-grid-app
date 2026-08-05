import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../network/presentation/grid_overview_widgets.dart';

/// How much of the assistant's working-out a chat shows while it answers.
///
/// It lives on the Appearance screen because that is the question it answers —
/// how much of this do I want to look at — and because there is exactly one
/// setting, which would be a screen of its own for no reason.
class DetailModeSection extends ConsumerWidget {
  const DetailModeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final current = ref.watch(chatPrefsProvider.select((p) => p.detail));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'Conversations',
          subtitle:
              'How much of the assistant’s working-out to show while it '
              'answers. The answer itself is always the same.',
        ),
        const SizedBox(height: 12),
        AppSegmented(
          segments: [
            for (final mode in AgentDetailMode.values)
              SegmentSpec(label: detailModeLabel(mode)),
          ],
          selected: AgentDetailMode.values.indexOf(current),
          onChanged: (index) => ref
              .read(chatPrefsProvider.notifier)
              .setDetail(AgentDetailMode.values[index]),
        ),
        const SizedBox(height: 8),
        Text(
          detailModeDetail(current),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}

/// The one-word name of each level, as the control shows it.
String detailModeLabel(AgentDetailMode mode) => switch (mode) {
  AgentDetailMode.answer => 'Answer only',
  AgentDetailMode.steps => 'Steps',
  AgentDetailMode.stepsCommands => 'Steps and commands',
};

/// What choosing that level actually changes, in one line under the control —
/// so the difference between the middle and the right-hand choice isn't
/// something you have to switch back and forth to discover.
String detailModeDetail(AgentDetailMode mode) => switch (mode) {
  AgentDetailMode.answer =>
    'Just the reply. No list of what the assistant did to get there.',
  AgentDetailMode.steps =>
    'Each thing it does, in plain words — "Ran rg", "Searched the web".',
  AgentDetailMode.stepsCommands =>
    'Each step with the command line it ran. Useful when something goes wrong.',
};
