part of 'new_job_dialog.dart';

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
            _PillChoice(
              label: Text(option.label),
              selected: option == cadence,
              icon: option == cadence ? Icons.check_rounded : null,
              onTap: () => onChanged(option),
            ),
        ],
      ),
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow({required this.weekday, required this.onChanged});

  final int weekday;
  final ValueChanged<int> onChanged;

  static const _days = {
    DateTime.monday: 'Mon',
    DateTime.tuesday: 'Tue',
    DateTime.wednesday: 'Wed',
    DateTime.thursday: 'Thu',
    DateTime.friday: 'Fri',
    DateTime.saturday: 'Sat',
    DateTime.sunday: 'Sun',
  };

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final entry in _days.entries)
            _PillChoice(
              label: Text(entry.value),
              selected: entry.key == weekday,
              onTap: () => onChanged(entry.key),
            ),
        ],
      ),
    );
  }
}

class _PillChoice extends StatelessWidget {
  const _PillChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final Widget label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : Colors.white,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? AppPalette.accent : AppPalette.divider,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 8),
              ],
              DefaultTextStyle.merge(
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                child: label,
              ),
            ],
          ),
        ),
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
        const Text('At', style: TextStyle(color: AppPalette.textSecondary)),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: onPick,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppPalette.accent,
            side: const BorderSide(color: AppPalette.divider),
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.schedule_rounded, size: 16),
          label: Text(time.format(context)),
        ),
      ],
    );
  }
}
