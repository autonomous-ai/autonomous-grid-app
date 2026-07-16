import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_task_policy.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../logic/task_power_controller.dart';

/// What tasks are allowed to do to this computer — stated on the screen that
/// creates them, not buried in a settings page.
///
/// A task fires whether the app is open or not, so nobody can be asked at the
/// time. That makes this the one place the user gets to decide, and the copy says
/// exactly what each choice costs — including the default, which lets a task
/// change files and run commands with no one to say no.
class TaskPowerBar extends ConsumerWidget {
  const TaskPowerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final power = ref.watch(taskPowerProvider).value;
    if (power == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final risky = power == TaskPower.fullAccess;
    final color = risky ? AppPalette.warn : AppPalette.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(taskPowerIcon(power), size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              taskPowerDetail(power),
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          const SizedBox(width: 8),
          _ChangeButton(current: power),
        ],
      ),
    );
  }
}

/// Opens the two choices. Deliberately a plain menu, not a switch: "full access"
/// isn't a feature toggle, it's a decision with a consequence to read.
class _ChangeButton extends ConsumerStatefulWidget {
  const _ChangeButton({required this.current});

  final TaskPower current;

  @override
  ConsumerState<_ChangeButton> createState() => _ChangeButtonState();
}

class _ChangeButtonState extends ConsumerState<_ChangeButton> {
  final _menu = MenuController();

  Future<void> _select(TaskPower power) async {
    _menu.close();
    if (power == widget.current) return;
    final error = await ref.read(taskPowerProvider.notifier).set(power);
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        for (final power in TaskPower.values)
          _PowerItem(
            power: power,
            selected: power == widget.current,
            onTap: () => _select(power),
          ),
      ],
      builder: (context, controller, _) => TextButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: const Text('Change access'),
      ),
    );
  }
}

class _PowerItem extends StatelessWidget {
  const _PowerItem({
    required this.power,
    required this.selected,
    required this.onTap,
  });

  final TaskPower power;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final risky = power == TaskPower.fullAccess;
    return MenuItemButton(
      onPressed: onTap,
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  taskPowerIcon(power),
                  size: 17,
                  color: risky ? AppPalette.warn : AppPalette.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      taskPowerLabel(power),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      taskPowerDetail(power),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: risky
                            ? AppPalette.warn
                            : AppPalette.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.check_rounded,
                size: 16,
                color: selected ? AppPalette.accent : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name of a setting, as the user reads it — what it lets a task do, not how
/// it's wired ("no commands" was the config talking).
String taskPowerLabel(TaskPower power) => switch (power) {
  TaskPower.fullAccess => 'Full access',
  TaskPower.noCommands => 'Files only',
};

/// What it actually means, in plain terms. No euphemism for the default — a task
/// running at 8am with nobody watching is exactly when a surprise costs the most.
String taskPowerDetail(TaskPower power) => switch (power) {
  TaskPower.fullAccess =>
    'Tasks can change your files and run programs on your computer, with '
        'nobody there to approve it.',
  TaskPower.noCommands =>
    'Tasks can read and edit files in your project, but can\'t run any '
        'programs on your computer.',
};

IconData taskPowerIcon(TaskPower power) => switch (power) {
  TaskPower.fullAccess => Icons.bolt_outlined,
  TaskPower.noCommands => Icons.shield_outlined,
};
