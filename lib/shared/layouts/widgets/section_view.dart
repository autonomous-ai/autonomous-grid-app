import 'package:flutter/material.dart';

import '../../../features/agents/presentation/agents_view.dart';
import '../../../features/chat/presentation/chat_pane.dart';
import '../../../features/debug/presentation/debug_view.dart';
import '../../../features/messaging/presentation/telegram_view.dart';
import '../../../features/network/presentation/how_to_use_view.dart';
import '../../../features/network/presentation/networks_pane.dart';
import '../../../features/plugins/presentation/plugins_view.dart';
import '../../../features/projects/presentation/projects_view.dart';
import '../../../features/provider_node/presentation/provider_view.dart';
import '../../../features/scheduled/presentation/scheduled_view.dart';
import '../shell_state.dart';

/// The screen behind a [ShellSection].
///
/// The single place that mapping lives: the app shell and Settings both draw
/// sections, and a section must be the same screen wherever it was opened from.
class SectionView extends StatelessWidget {
  const SectionView({super.key, required this.section});

  final ShellSection section;

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      ShellSection.chat => const ChatPane(),
      ShellSection.scheduled => const ScheduledView(),
      ShellSection.agents => const AgentsView(),
      ShellSection.plugins => const PluginsView(),
      ShellSection.projects => const ProjectsView(),
      ShellSection.telegram => const TelegramView(),
      ShellSection.grids => const NetworksPane(),
      ShellSection.engines => const ProviderView(),
      ShellSection.guide => const HowToUseView(),
      ShellSection.debug => const DebugView(),
    };
  }
}
