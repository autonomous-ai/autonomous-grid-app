part of 'new_job_dialog.dart';

/// When it runs, where — and what it's allowed to do while nobody is watching.
/// The last part is the one the user can't guess, so it isn't left out.
class _WhatItMayDo extends ConsumerWidget {
  const _WhatItMayDo({required this.schedule, this.location});

  final JobSchedule schedule;

  /// Where the task runs, already worded ("in your Projects folder", `in "Foo"`)
  /// — or null when the form can't say, which leaves the sentence at what it
  /// does know rather than guessing a folder.
  final String? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final power = ref.watch(taskPowerProvider).value;
    final risky = power == TaskPower.fullAccess;
    final where = location == null ? '' : ', $location';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoLine(
            icon: Icons.folder_outlined,
            text:
                'Runs ${schedule.describe().toLowerCase()}, on this '
                'computer$where.',
          ),
          // The asleep warning is about a single nightly time; an interval task
          // runs all day, so it doesn't apply the same way.
          if (!schedule.cadence.isInterval && _asleepHour(schedule.hour)) ...[
            const SizedBox(height: 9),
            _InfoLine(
              icon: Icons.bedtime_outlined,
              text:
                  'Only runs while your computer is awake. At '
                  '${_hourLabel(schedule.hour)} it may be asleep — that run is '
                  'skipped, not caught up later.',
            ),
          ],
          if (power != null) ...[
            const SizedBox(height: 9),
            _InfoLine(
              icon: taskPowerIcon(power),
              text: taskPowerDetail(power),
              tone: risky ? AppPalette.warn : null,
            ),
          ],
        ],
      ),
    );
  }

  /// The hours a personal computer is most likely asleep. A deliberately narrow
  /// window — we warn about 3am, not about lunchtime, so the note stays rare
  /// enough to mean something when it appears.
  static bool _asleepHour(int hour) => hour >= 0 && hour < 7;

  static String _hourLabel(int hour) => '${hour.toString().padLeft(2, '0')}:00';
}

/// One icon-led fact in the info card. [tone] colours both icon and text when a
/// line needs to warn (Full access), otherwise it reads as quiet secondary text.
class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text, this.tone});

  final IconData icon;
  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? AppPalette.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: color),
          ),
        ),
      ],
    );
  }
}

/// The task's schedule as Hermes holds it, when this form can't draw it — a job
/// written straight into Hermes, or an interval the app doesn't offer.
///
/// Shown rather than swallowed: the cadence row underneath would otherwise read
/// as what the task runs on, and saving would replace a schedule the user never
/// meant to touch.
class _ForeignScheduleNote extends StatelessWidget {
  const _ForeignScheduleNote({required this.expression});

  final String expression;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return _InfoLine(
      icon: Icons.schedule_outlined,
      text:
          'This task runs on "$expression", which this form can\'t show. '
          'Saving replaces it with the schedule you pick here.',
      tone: AppPalette.warn,
    );
  }
}

class _DialogTitle extends StatelessWidget {
  const _DialogTitle({required this.editing});

  final bool editing;

  @override
  Widget build(BuildContext context) {
    return Text(
      editing ? 'Edit scheduled task' : 'New scheduled task',
      style: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 21,
        fontWeight: AppFont.semibold,
        letterSpacing: -0.3,
        height: 1.12,
      ),
    );
  }
}
