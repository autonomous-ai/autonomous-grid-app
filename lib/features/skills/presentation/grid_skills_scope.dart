import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_skill_installer.dart';
import '../../agents/logic/agent_catalog.dart';

/// Puts Grid's own skills in Hermes's folder, once, at launch.
///
/// They used to reach Hermes through `skills.external_dirs`, which pointed it
/// at the whole app library — every skill in there, given to Hermes or not.
/// Now they reach it the same way any other skill does: as a copy in its own
/// folder, written by the installer. Doing that at launch is what makes it
/// automatic rather than something the user has to think about.
///
/// A widget rather than a call in `main()` for the reason
/// `ConnectorRefreshScope` is one: the installer is read from providers, and
/// the `ProviderScope` they live in only exists inside the tree. It draws
/// nothing and rebuilds nothing — [child] passes straight through.
///
/// Above the router, because these skills are for the agent and the agent
/// answers chats whether or not the Skills screen is ever opened. Codex gets
/// its own copies the first time a chat goes to Codex — nothing here, since a
/// machine with no Codex on it has no folder to write into.
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
      try {
        await ref
            .read(agentSkillInstallerProvider)
            .install(AgentTool.hermes);
      } on Object {
        // Best-effort, exactly as on the grid-link path: a failed install costs
        // the user Grid's own skills for this session, and must not cost them
        // the app.
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
