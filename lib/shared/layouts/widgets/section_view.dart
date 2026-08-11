import 'package:flutter/material.dart';

import '../../../features/agents/presentation/agents_view.dart';
import '../../../features/appearance/presentation/appearance_view.dart';
import '../../../features/chat/presentation/archived_chats_view.dart';
import '../../../features/chat/presentation/chat_pane.dart';
import '../../../features/connectors/presentation/connectors_view.dart';
import '../../../features/data_sync/presentation/data_sync_view.dart';
import '../../../features/debug/presentation/debug_view.dart';
import '../../../features/git/presentation/git_view.dart';
import '../../../features/messaging/presentation/messages_view.dart';
import '../../../features/network/presentation/how_to_use_view.dart';
import '../../../features/network/presentation/networks_pane.dart';
import '../../../features/plugins/presentation/plugins_view.dart';
import '../../../features/projects/presentation/projects_view.dart';
import '../../../features/provider_node/presentation/provider_view.dart';
import '../../../features/scheduled/presentation/scheduled_view.dart';
import '../../../features/skills/presentation/skills_view.dart';
import '../shell_state.dart';

/// The screen behind a [ShellSection].
///
/// The single place that mapping lives: the app shell and Settings both draw
/// sections, and a section must be the same screen wherever it was opened from.
///
/// Switching sections cross-fades rather than cutting: a screen that appears the
/// instant you click reads as a jolt, and the rail's own row highlight already
/// animates — the pane arriving in step with it makes the two feel like one
/// movement instead of a snap.
class SectionView extends StatelessWidget {
  const SectionView({super.key, required this.section});

  final ShellSection section;

  @override
  Widget build(BuildContext context) {
    final screen = switch (section) {
      ShellSection.chat => const ChatPane(),
      ShellSection.scheduled => const ScheduledView(),
      ShellSection.agents => const AgentsView(),
      ShellSection.skills => const SkillsView(),
      ShellSection.connectors => const ConnectorsView(),
      ShellSection.plugins => const PluginsView(),
      ShellSection.projects => const ProjectsView(),
      ShellSection.git => const GitView(),
      ShellSection.messages => const MessagesView(),
      ShellSection.grids => const NetworksPane(),
      ShellSection.engines => const ProviderView(),
      ShellSection.guide => const HowToUseView(),
      ShellSection.appearance => const AppearanceView(),
      ShellSection.dataSync => const DataSyncView(),
      ShellSection.archived => const ArchivedChatsView(),
      ShellSection.debug => const DebugView(),
    };

    return AnimatedSwitcher(
      // Fade-through: the outgoing screen clears before the incoming one is more
      // than a ghost, so the two never read as a muddle of overlapping text. The
      // exit is the shorter half — waiting on it is what makes a cross-fade feel
      // sluggish.
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 90),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      // Keyed by section, not by widget type: that's what tells the switcher a
      // *different screen* arrived. Without it the panes are all just Widgets and
      // it would cut between them exactly as before.
      child: KeyedSubtree(key: ValueKey(section), child: screen),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        // A whisper of rise on the way in, matching the sidebar's own rows —
        // enough to read as "this arrived", not so much that it slides.
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.012),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        // Both screens fill the pane while they trade places, and the incoming
        // one sits on top — anchored to the top-left so a pane that's taller than
        // the window doesn't jump as the old one leaves.
        alignment: Alignment.topLeft,
        children: [
          for (final child in previousChildren) Positioned.fill(child: child),
          if (currentChild != null) Positioned.fill(child: currentChild),
        ],
      ),
    );
  }
}
