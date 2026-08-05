import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/chat_goal.dart';

/// What the user asked for when they set a goal: the objective and its ceilings.
typedef GoalRequest = ({String objective, int maxTurns, int maxMinutes});

/// Ask what the assistant should work toward on its own, and for how long.
///
/// Returns null when the user cancels or leaves the objective blank — a goal
/// with nothing in it would send turns about nothing.
Future<GoalRequest?> showGoalDialog(BuildContext context) async {
  final objective = TextEditingController();
  try {
    return await showDialog<GoalRequest>(
      context: context,
      builder: (context) => _GoalDialog(objective: objective),
    );
  } finally {
    // After the frame: the dialog animates out and rebuilds its fields on the
    // way, which would read a controller disposed out from under it.
    WidgetsBinding.instance.addPostFrameCallback((_) => objective.dispose());
  }
}

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({required this.objective});

  final TextEditingController objective;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  int _turns = kDefaultGoalTurns;
  int _minutes = kDefaultGoalMinutes;

  bool get _canStart => widget.objective.text.trim().isNotEmpty;

  void _submit() {
    if (!_canStart) return;
    Navigator.pop(context, (
      objective: widget.objective.text.trim(),
      maxTurns: _turns,
      maxMinutes: _minutes,
    ));
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      // The menus' fill, lifted clear of the window it opens over — see
      // `showRenameChatDialog` for why windowBg would be an edgeless slab.
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppGlass.hair),
      ),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Text(
        'Set a goal',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            Text(
              'The assistant keeps working on this by itself, one turn after '
              'another, until it says the goal is met or it runs out of what '
              'you allow below. You can pause it at any time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            LabeledField(
              label: 'What should it get done',
              controller: widget.objective,
              hint: 'Get the test suite passing on this branch',
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            _BudgetRow(
              label: 'Stop after',
              value: _turns,
              unit: 'turns',
              choices: const [5, 10, 20, 50],
              onChanged: (value) => setState(() => _turns = value),
            ),
            const SizedBox(height: 10),
            _BudgetRow(
              label: 'Or after',
              value: _minutes,
              unit: 'minutes',
              choices: const [10, 30, 60, 120],
              onChanged: (value) => setState(() => _minutes = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canStart ? _submit : null,
          child: const Text('Start'),
        ),
      ],
    );
  }
}

/// One ceiling, as a row of choices rather than a number field — the point is to
/// pick a bound quickly, not to type 37.
class _BudgetRow extends StatelessWidget {
  const _BudgetRow({
    required this.label,
    required this.value,
    required this.unit,
    required this.choices,
    required this.onChanged,
  });

  final String label;
  final int value;
  final String unit;
  final List<int> choices;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final choice in choices)
                ChoiceChip(
                  label: Text('$choice $unit'),
                  selected: choice == value,
                  onSelected: (_) => onChanged(choice),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
