import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/composer_trigger.dart';
import '../logic/active_chat_agent.dart';
import '../logic/agent_catalog.dart';
import 'agent_mark.dart';
import '../logic/agent_grid_support.dart';
import '../logic/agent_status.dart';

/// The composer's control for **which agent** answers the chat — the other half
/// of "what happens when I press Send", sitting next to the model it runs.
///
/// Lists the agents installed on this computer; the one in force wears a tick.
/// Picking one saves it as the chat's agent ([ChatPrefs.chatAgent]); an agent
/// this grid can't run is offered but marked, so the choice is honest rather
/// than silently handed back (the handover bar explains the swap). Shown only
/// when an agent is the one answering (the composer gates it on that).
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
    ref.read(chatPrefsProvider.notifier).setChatAgent(tool.id);
    _menu.close();
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
    final installed = [
      for (final tool in AgentTool.values)
        if (ref.watch(agentInstalledProvider(tool))) tool,
    ];
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
        for (final tool in installed)
          _AgentItem(
            tool: tool,
            selected: tool == active,
            unavailable: _unavailableNote(tool),
            onTap: () => _select(tool),
          ),
      ],
      builder: (context, controller, _) => ComposerTrigger(
        label: active.name,
        tooltip: 'Which agent answers · ${active.name}',
        leading: AgentMark(tool: active, size: 14),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
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
