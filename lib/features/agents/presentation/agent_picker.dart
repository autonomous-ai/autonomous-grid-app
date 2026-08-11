import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/composer_trigger.dart';
import '../../chat/logic/chat_scope.dart';
import '../logic/active_chat_agent.dart';
import '../logic/agent_catalog.dart';
import '../logic/auto_agent.dart';
import '../logic/auto_agent_router.dart';
import 'agent_mark.dart';
import '../logic/agent_grid_support.dart';
import '../logic/agent_status.dart';

/// The composer's control for **which agent** answers the chat — the other half
/// of "what happens when I press Send", sitting next to the model it runs.
///
/// Lists the agents installed on this computer; the one in force wears a tick.
/// Picking one saves it where the chat lives — on its **project** when it has
/// one, else as the app's standing choice (see [ChatScopePrefs]) — and the menu
/// says which, so a pick that follows you between projects is never a surprise.
/// An agent this grid can't run is offered but marked, so the choice is honest
/// rather than silently handed back (the handover bar explains the swap). Shown
/// only when an agent is the one answering (the composer gates it on that).
class AgentPicker extends ConsumerStatefulWidget {
  const AgentPicker({super.key});

  @override
  ConsumerState<AgentPicker> createState() => _AgentPickerState();
}

const _menuWidth = 260.0;
const _rowGutter = 8.0;
const _rowInnerPad = 10.0;
final _rowRadius = BorderRadius.circular(AppControl.radius);

class _AgentPickerState extends ConsumerState<AgentPicker> {
  final _menu = MenuController();

  void _select(AgentTool tool) {
    ref.read(chatScopePrefsProvider).setAgent(tool.id);
    _menu.close();
  }

  /// Pick Auto: the grid chooses which installed assistant answers each
  /// question. Stored like any other agent choice — a sentinel id in the same
  /// slot — so a project keeps its own, and the model it runs on is decided at
  /// send time (the grid's auto model).
  void _selectAuto() {
    ref.read(chatScopePrefsProvider).setAgent(kAutoAgentId);
    _menu.close();
  }

  /// The trigger's tooltip — under Auto it names the assistant *currently*
  /// answering too, so the row doesn't just say "Auto" while a real agent
  /// replies underneath it.
  String _triggerTooltip(bool autoChosen, AgentTool active, String? project) {
    if (autoChosen) {
      final where = project == null ? '' : ' in $project';
      return 'Auto$where · the grid picks per question (now: ${active.name})';
    }
    return project == null
        ? 'Which agent answers · ${active.name}'
        : 'Which agent answers in $project · ${active.name}';
  }

  /// Why [tool] can't answer on the open grid, or null when it can.
  ///
  /// Two different walls, said apart: the grid answers no dialect this agent
  /// speaks at all, or it does but serves nothing this agent can be pointed at
  /// (a grid of `claude:*` models with Codex in force). One wording for both
  /// would send a user hunting for the wrong fix — the second clears the moment
  /// they pick another model, the first only on another grid.
  String? _unavailableNote(AgentTool tool) {
    if (!ref.watch(agentRunsOnGridProvider(tool))) {
      return 'Not available on this grid — pick borrows chat until a grid '
          'that runs it.';
    }
    if (!ref.watch(agentHasModelHereProvider(tool))) {
      return 'No model on this grid it can answer with.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The anchor's MenuStyle reads a token (cardBg); follow theme flips.
    AppTheme.watch(context);
    final active = ref.watch(activeChatAgentProvider);
    final autoChosen = ref.watch(isAutoAgentChosenProvider);
    final installed = [
      for (final tool in AgentTool.values)
        if (ref.watch(agentInstalledProvider(tool))) tool,
    ];
    // Auto is offered only when there's a real choice to make — two or more
    // installed agents. With one, "let the grid pick" would always pick it, so
    // the row would be a longer way to say what a single agent already says.
    final offerAuto = installed.length > 1;
    // Where the pick will be remembered, said out loud: in a project the choice
    // is that project's and changes nothing anywhere else, which is the whole
    // point of it — and it explains why the agent changed when they switched.
    final project = ref.watch(openChatProjectProvider);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, -8),
      style: MenuStyle(
        alignment: Alignment.topLeft,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        backgroundColor: WidgetStatePropertyAll(AppPalette.cardBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        if (offerAuto) _AutoItem(selected: autoChosen, onTap: _selectAuto),
        for (final tool in installed)
          _AgentItem(
            tool: tool,
            // A concrete agent is ticked only when it's the *chosen* one — under
            // Auto none is, even though one is currently answering, or the list
            // would show two ticks and hide that the grid is choosing.
            selected: !autoChosen && tool == active,
            unavailable: _unavailableNote(tool),
            onTap: () => _select(tool),
          ),
        _ScopeNote(projectName: project?.name),
      ],
      builder: (context, controller, _) => ComposerTrigger(
        label: autoChosen ? 'Auto' : active.name,
        tooltip: _triggerTooltip(autoChosen, active, project?.name),
        leading: autoChosen
            ? Icon(Icons.auto_awesome, size: 14, color: AppPalette.accent)
            : AgentMark(tool: active, size: 14),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The line under the list that says who the pick belongs to: this project, or
/// every chat outside one.
///
/// One sentence, in the user's terms — "your other projects keep theirs" is the
/// fact that stops a per-project setting reading as an app-wide one that keeps
/// changing itself.
class _ScopeNote extends StatelessWidget {
  const _ScopeNote({required this.projectName});

  final String? projectName;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _rowGutter + _rowInnerPad,
        6,
        _rowGutter + _rowInnerPad,
        4,
      ),
      child: SizedBox(
        width: _menuWidth - (_rowGutter + _rowInnerPad) * 2,
        child: Text(
          projectName == null
              ? 'Saved for chats outside a project. Each project keeps its own.'
              : 'Saved for $projectName. Your other projects keep theirs.',
          style: TextStyle(
            color: AppPalette.textFaint,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

/// The Auto row at the top of the list: a wand, the word "Auto", and the line
/// that says what it does. Reuses the same box as [_AgentItem] so it reads as a
/// peer of the agents it chooses between, not a setting bolted above them.
class _AutoItem extends StatelessWidget {
  const _AutoItem({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        splashFactory: NoSplash.splashFactory,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: _rowRadius),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _rowGutter,
          vertical: 3,
        ),
        child: Container(
          width: _menuWidth - _rowGutter * 2,
          padding: const EdgeInsets.fromLTRB(_rowInnerPad, 8, 8, 8),
          decoration: BoxDecoration(
            color: selected ? AppSurface.accentWash : Colors.transparent,
            borderRadius: _rowRadius,
          ),
          child: Row(
            children: [
              // A 20px box like AgentMark, so the wand lines up with the agent
              // icons under it rather than sitting a few pixels off.
              SizedBox(
                width: 20,
                height: 20,
                child: Icon(
                  Icons.auto_awesome,
                  size: 18,
                  color: AppPalette.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: AppFont.medium,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      kAutoAgentTagline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_rounded, size: 16, color: AppPalette.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One agent row: its mark, its name and one-line tagline, the reason it can't
/// answer here when there is one, and a tick when it's the one answering.
class _AgentItem extends StatelessWidget {
  const _AgentItem({
    required this.tool,
    required this.selected,
    required this.unavailable,
    required this.onTap,
  });

  final AgentTool tool;
  final bool selected;

  /// Why this agent can't answer on the open grid — shown in place of the
  /// tagline, in the warning tone. Null whenever it can, which is the common
  /// case. An installed agent is still offered either way: picking it borrows
  /// the chat until a grid that can run it.
  final String? unavailable;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        splashFactory: NoSplash.splashFactory,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: _rowRadius),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _rowGutter,
          vertical: 3,
        ),
        child: Container(
          width: _menuWidth - _rowGutter * 2,
          padding: const EdgeInsets.fromLTRB(_rowInnerPad, 8, 8, 8),
          decoration: BoxDecoration(
            color: selected ? AppSurface.accentWash : Colors.transparent,
            borderRadius: _rowRadius,
          ),
          child: Row(
            children: [
              AgentMark(tool: tool, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tool.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: AppFont.medium,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      unavailable ?? tool.tagline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: unavailable == null
                            ? AppPalette.textSecondary
                            : AppPalette.warn,
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_rounded, size: 16, color: AppPalette.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
