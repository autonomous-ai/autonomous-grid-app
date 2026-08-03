import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_skill_installer.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_status.dart';

/// Puts Grid's own skills in every installed agent's folder, at launch.
///
/// Every agent, not just Hermes: an agent only knows a skill it finds in its
/// own folder, and Hermes was the only one being served at launch — the other
/// two waited until a chat happened to go their way, so a Codex the user hadn't
/// chatted with since the skills shipped simply didn't have them.
///
/// They used to reach Hermes a different way, through `skills.external_dirs`,
/// which pointed it at the whole app library — every skill in there, given to
/// Hermes or not. Now every agent gets them the same way any other skill
/// arrives: as a copy in its own folder.
///
/// A widget rather than a call in `main()` for the reason
/// `ConnectorRefreshScope` is one: the installer is read from providers, and
/// the `ProviderScope` they live in only exists inside the tree. It draws
/// nothing and rebuilds nothing — [child] passes straight through.
///
/// Above the router, because these skills are for the agents and an agent
/// answers chats whether or not the Skills screen is ever opened. The chat
/// senders still install too — that stays, as the one path that covers an agent
/// installed *after* launch — and costs nothing now that a folder already
/// holding the skill is left alone.
class GridSkillsScope extends ConsumerStatefulWidget {
  const GridSkillsScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<GridSkillsScope> createState() => _GridSkillsScopeState();
}

class _GridSkillsScopeState extends ConsumerState<GridSkillsScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: this writes a dozen small folders, and the window
    // should not wait on disk for something nobody is watching.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      for (final agent in AgentTool.values) {
        // Only agents that are actually here. Installing for one that isn't
        // would create `~/.codex/skills` on a machine with no Codex — a folder
        // for software the user doesn't have, which reads as a mess they
        // didn't make.
        if (!ref.read(agentInstalledProvider(agent))) continue;
        try {
          await ref.read(agentSkillInstallerProvider).install(agent);
        } on Object {
          // Best-effort per agent, and one failure must not skip the rest:
          // Codex missing its skills is no reason for Hermes to go without.
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
