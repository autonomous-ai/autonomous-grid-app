part of 'new_job_dialog.dart';

/// Which model the task answers with — pinned to it, so it keeps running on
/// what was picked here when the chat moves to another one.
///
/// Only models the assistant can actually answer with are offered (a Claude or
/// Codex seat is another vendor's CLI behind the relay, and a task pointed at
/// one comes back with the tool call typed out instead of a report). `auto` sits
/// at the top as the grid's own router: it picks a model per run, so it survives
/// one machine going off.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.options,
    required this.model,
    required this.onChanged,
  });

  /// What this grid serves that a task could run on — resolved by the dialog's
  /// own build, so the row and the model the task is saved with can't disagree.
  final List<PlaygroundModelOption> options;

  final String model;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return Text(
        "This grid isn't sharing a model the assistant can use yet, so a task "
        'would have nothing to answer with.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.35,
          color: AppPalette.textSecondary,
        ),
      );
    }
    return AppSelectField<String>(
      label: 'Which model runs it',
      showLabel: false,
      value: model,
      options: [
        for (final option in options)
          AppSelectOption(
            value: option.id,
            label: option.id == kAutoModelId
                ? 'Auto — the grid picks'
                : modelDisplayLabel(option.id),
            detail: option.id == kAutoModelId
                ? 'Keeps working when one machine goes off'
                : null,
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class _CadenceRow extends StatelessWidget {
  const _CadenceRow({required this.cadence, required this.onChanged});

  final JobCadence cadence;
  final ValueChanged<JobCadence> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in JobCadence.values)
            ScheduledPillChoice(
              label: Text(option.label),
              selected: option == cadence,
              onTap: () => onChanged(option),
            ),
        ],
      ),
    );
  }
}

/// Which days the task runs on — several, not one.
///
/// The last day on can't be turned off: a schedule with no days would be a task
/// that never runs, saved as if it would.
class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow({required this.days, required this.onChanged});

  final Set<int> days;
  final ValueChanged<Set<int>> onChanged;

  static const _labels = {
    DateTime.monday: 'Mon',
    DateTime.tuesday: 'Tue',
    DateTime.wednesday: 'Wed',
    DateTime.thursday: 'Thu',
    DateTime.friday: 'Fri',
    DateTime.saturday: 'Sat',
    DateTime.sunday: 'Sun',
  };

  /// [days] with [day] flipped — unless it is the only one left on.
  Set<int> _toggled(int day) {
    if (!days.contains(day)) return {...days, day};
    if (days.length == 1) return days;
    return {...days}..remove(day);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final entry in _labels.entries)
            ScheduledPillChoice(
              label: Text(entry.value),
              selected: days.contains(entry.key),
              onTap: () => onChanged(_toggled(entry.key)),
            ),
        ],
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.time, required this.onPick});

  final TimeOfDay time;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('At', style: TextStyle(color: AppPalette.textSecondary)),
        const SizedBox(width: 12),
        // The time reads as the value it is, so it keeps the accent; the rest of
        // the button comes from the app's outlined-button theme.
        OutlinedButton.icon(
          onPressed: onPick,
          style: OutlinedButton.styleFrom(foregroundColor: AppPalette.accent),
          icon: const Icon(Icons.schedule_rounded, size: AppControl.iconSize),
          label: Text(time.format(context)),
        ),
      ],
    );
  }
}
