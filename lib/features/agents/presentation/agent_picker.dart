import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/active_chat_agent.dart';
import '../logic/agent_catalog.dart';
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
            // An installed agent this grid serves no model for still shows, but
            // says so — picking it borrows the chat until a grid that can run it.
            runsHere: ref.watch(agentRunsOnGridProvider(tool)),
            onTap: () => _select(tool),
          ),
      ],
      builder: (context, controller, _) => _Trigger(
        tool: active,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The pill in the composer: the agent in force, its mark, and a caret.
class _Trigger extends StatelessWidget {
  const _Trigger({required this.tool, required this.onTap});

  final AgentTool tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return Tooltip(
      message: 'Which agent answers · ${tool.name}',
      child: Material(
        color: AppGlass.surfaceFill,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppGlass.surfaceHoverFill,
          child: Container(
            height: AppControl.heightSmall,
            padding: const EdgeInsets.only(left: 7, right: 7),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: AppGlass.hair),
              boxShadow: AppGlass.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AgentMark(tool: tool, size: 14),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    tool.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more_rounded,
                  size: 14,
                  color: AppPalette.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One agent row: its mark, its name and one-line tagline, a "not on this grid"
/// note when it can't run here, and a tick when it's the one answering.
class _AgentItem extends StatelessWidget {
  const _AgentItem({
    required this.tool,
    required this.selected,
    required this.runsHere,
    required this.onTap,
  });

  final AgentTool tool;
  final bool selected;
  final bool runsHere;
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
              _AgentMark(tool: tool, size: 20),
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
                      runsHere
                          ? tool.tagline
                          : "Not available on this grid — pick borrows chat "
                                "until a grid that runs it.",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: runsHere
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

/// An agent's bundled mark, drawn as its own image (not a tinted glyph) since
/// each is a real logo with its own colour — the same treatment the Agents list
/// gives it.
class _AgentMark extends StatelessWidget {
  const _AgentMark({required this.tool, required this.size});

  final AgentTool tool;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.asset(
        tool.iconAsset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // A missing/undeclared asset must not crash the composer — fall back to a
        // neutral glyph (agent_catalog_test guards the real assets in CI).
        errorBuilder: (_, _, _) => Icon(
          Icons.smart_toy_outlined,
          size: size,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
