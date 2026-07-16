part of 'new_job_dialog.dart';

/// Where the answer lands when the task has run.
///
/// Telegram is only offered once a bot is actually connected — an option that
/// silently does nothing is worse than no option at all. The row says why it's
/// out of reach, and where to fix that.
class _DeliverRow extends ConsumerWidget {
  const _DeliverRow({required this.toTelegram, required this.onChanged});

  final bool toTelegram;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(telegramProvider).value is TelegramConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send the answer to',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ScheduledPillChoice(
              label: const Text('This app'),
              selected: !toTelegram,
              onTap: () => onChanged(false),
            ),
            Tooltip(
              message: connected
                  ? 'Your Telegram chat with the bot'
                  : 'Connect a Telegram bot first (account menu ▸ Telegram)',
              child: ScheduledPillChoice(
                label: Text(
                  'Telegram',
                  style: TextStyle(
                    color: connected ? null : AppPalette.textFaint,
                  ),
                ),
                selected: toTelegram,
                onTap: () => connected
                    ? onChanged(true)
                    : ref
                          .read(shellSectionProvider.notifier)
                          .select(ShellSection.telegram),
              ),
            ),
          ],
        ),
      ],
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
            ScheduledPillChoice(
              label: Text(entry.value),
              selected: entry.key == weekday,
              onTap: () => onChanged(entry.key),
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
