import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../logic/agent_permissions.dart';

/// The composer's control for how much the assistant may do to this computer.
///
/// It sits next to the model, because it's the other half of "what happens when I
/// press Send": who answers, and what they're allowed to touch. The choice sticks
/// until it's changed, and every menu line says plainly what it costs — including
/// the one that stops asking altogether.
class ApprovalPicker extends ConsumerStatefulWidget {
  const ApprovalPicker({super.key});

  @override
  ConsumerState<ApprovalPicker> createState() => _ApprovalPickerState();
}

class _ApprovalPickerState extends ConsumerState<ApprovalPicker> {
  static const _menuSize = Size(340, 292);

  final _menu = MenuController();

  void _select(AgentApprovalMode mode) {
    ref.read(chatPrefsProvider.notifier).setApproval(mode);
    _menu.close();
  }

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize,
        preferAbove: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(agentApprovalModeProvider);
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
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
        const SizedBox(width: 340, child: _MenuHeading()),
        for (final mode in AgentApprovalMode.values)
          _ModeItem(
            mode: mode,
            selected: mode == current,
            onTap: () => _select(mode),
          ),
      ],
      builder: (context, controller, _) => _Trigger(
        mode: current,
        onTap: () => _toggleMenu(context, controller),
      ),
    );
  }
}

/// The pill in the composer: the mode in force, and a caret.
class _Trigger extends StatelessWidget {
  const _Trigger({required this.mode, required this.onTap});

  final AgentApprovalMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: approvalDetail(mode),
      child: Material(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            height: 28,
            padding: const EdgeInsets.only(left: 8, right: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: AppGlass.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  approvalIcon(mode),
                  size: 13,
                  color: AppPalette.textSecondary,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    approvalLabel(mode),
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

class _MenuHeading extends StatelessWidget {
  const _MenuHeading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 8, 14, 9),
      child: Text(
        'What may the assistant do on this computer?',
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One mode: what it is, what it means, and a tick when it's the one in force.
class _ModeItem extends StatelessWidget {
  const _ModeItem({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AgentApprovalMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final risky = mode == AgentApprovalMode.full;
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 324,
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0x062F5BEA) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ModeIcon(mode: mode),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      approvalLabel(mode),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.16,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      approvalDetail(mode),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: risky
                            ? AppPalette.warn
                            : AppPalette.textSecondary,
                        height: 1.28,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 18,
                child: Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: selected ? AppPalette.accent : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeIcon extends StatelessWidget {
  const _ModeIcon({required this.mode});

  final AgentApprovalMode mode;

  @override
  Widget build(BuildContext context) {
    final risky = mode == AgentApprovalMode.full;
    final color = risky ? AppPalette.warn : AppPalette.textSecondary;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(approvalIcon(mode), size: 15, color: color),
    );
  }
}

/// The name of a mode, as the user reads it in the composer.
String approvalLabel(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly => 'Read only',
  AgentApprovalMode.ask => 'Ask before acting',
  AgentApprovalMode.full => 'Full access',
};

/// What the mode actually means — no euphemisms for the one that stops asking.
String approvalDetail(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly =>
    'It can read your project files, but never change them or run anything.',
  AgentApprovalMode.ask =>
    'It shows you each command and each change to a file, and waits for a yes.',
  AgentApprovalMode.full =>
    'It runs commands and changes your files without asking. Nothing to undo.',
};

IconData approvalIcon(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly => Icons.visibility_outlined,
  AgentApprovalMode.ask => Icons.pan_tool_outlined,
  AgentApprovalMode.full => Icons.bolt_outlined,
};
