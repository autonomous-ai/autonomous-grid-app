import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_task_policy.dart';
import '../../../../shared/layouts/shell_state.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../messaging/logic/telegram_controller.dart';
import '../../logic/job_schedule.dart';
import '../../logic/job_suggestions.dart';
import '../../logic/scheduled_jobs_controller.dart';
import '../../logic/task_power_controller.dart';
import 'scheduled_pill_choice.dart';
import 'task_power_bar.dart';

part 'new_job_dialog_actions.dart';
part 'new_job_dialog_fields.dart';
part 'new_job_dialog_schedule.dart';

/// Asks for the three things a scheduled task needs — a name, what to do, and
/// when — and saves it with Hermes's scheduler.
///
/// No cron in sight: the user picks "every weekday at 08:00" and the app writes
/// the expression. Opened blank from "New task", or prefilled from a suggestion.
Future<void> showNewJobDialog(BuildContext context, {JobSuggestion? from}) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (_) => _NewJobDialog(suggestion: from),
    );

class _NewJobDialog extends ConsumerStatefulWidget {
  const _NewJobDialog({this.suggestion});

  final JobSuggestion? suggestion;

  @override
  ConsumerState<_NewJobDialog> createState() => _NewJobDialogState();
}

class _NewJobDialogState extends ConsumerState<_NewJobDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late JobCadence _cadence;
  late TimeOfDay _time;
  late int _weekday;
  bool _saving = false;

  /// Where the answer lands. Off by default: this app is where the user is
  /// standing, and posting to Telegram before they asked would be a surprise.
  bool _toTelegram = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.suggestion;
    final schedule =
        seed?.schedule ??
        const JobSchedule(cadence: JobCadence.everyDay, hour: 9, minute: 0);
    _name = TextEditingController(text: seed?.name ?? '');
    _prompt = TextEditingController(text: seed?.prompt ?? '');
    _cadence = schedule.cadence;
    _time = TimeOfDay(hour: schedule.hour, minute: schedule.minute);
    _weekday = schedule.weekday;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  JobSchedule get _schedule => JobSchedule(
    cadence: _cadence,
    hour: _time.hour,
    minute: _time.minute,
    weekday: _weekday,
  );

  bool get _canSave =>
      !_saving &&
      _name.text.trim().isNotEmpty &&
      _prompt.text.trim().isNotEmpty;

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) setState(() => _time = picked);
  }

  /// Fill the form from a ready-made idea, so "what should it do?" starts from an
  /// example instead of a blank box. Leaves anything the user already typed for a
  /// field only when that field is still empty — a half-written task isn't wiped.
  void _applyExample(JobSuggestion example) {
    setState(() {
      if (_name.text.trim().isEmpty) _name.text = example.name;
      _prompt.text = example.prompt;
      _cadence = example.schedule.cadence;
      _time = TimeOfDay(
        hour: example.schedule.hour,
        minute: example.schedule.minute,
      );
      _weekday = example.schedule.weekday;
    });
  }

  /// Save it, and — when [runNow] — kick off one run immediately so the user can
  /// see what it produces before trusting it to a schedule. Either way the new
  /// task is opened in the pane behind the dialog.
  Future<void> _save({bool runNow = false}) async {
    setState(() => _saving = true);
    final result = await ref
        .read(scheduledJobsProvider.notifier)
        .create(
          name: _name.text.trim(),
          prompt: _prompt.text.trim(),
          schedule: _schedule,
          toTelegram: _toTelegram,
          runNow: runNow,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    if (result.id != null) {
      ref.read(selectedJobIdProvider.notifier).select(result.id);
    }
    if (runNow) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Running it now — the answer lands in a moment.'),
        ),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      elevation: 18,
      backgroundColor: AppCard.base,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 508),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _DialogTitle(),
                const SizedBox(height: 4),
                Text(
                  'Work the assistant does on its own, on a timer.',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    color: AppPalette.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                _TaskField(
                  controller: _name,
                  label: 'Name',
                  hint: 'Daily digest',
                  autofocus: true,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 14),
                _TaskField(
                  controller: _prompt,
                  label: 'What should the assistant do?',
                  hint:
                      'Write it as if you were asking in a chat — the task has '
                      'to stand on its own.',
                  minLines: 4,
                  maxLines: 6,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 10),
                _ExampleRow(onPick: _applyExample),
                const SizedBox(height: 22),
                const _GroupLabel('When it runs'),
                const SizedBox(height: 10),
                _CadenceRow(
                  cadence: _cadence,
                  onChanged: (value) => setState(() => _cadence = value),
                ),
                if (_cadence == JobCadence.weekly) ...[
                  const SizedBox(height: 10),
                  _WeekdayRow(
                    weekday: _weekday,
                    onChanged: (value) => setState(() => _weekday = value),
                  ),
                ],
                // An interval cadence repeats through the day — there's no one
                // time to pick, so the time row would only mislead.
                if (!_cadence.isInterval) ...[
                  const SizedBox(height: 12),
                  _TimeRow(time: _time, onPick: _pickTime),
                ],
                const SizedBox(height: 22),
                const _GroupLabel('Where the answer goes'),
                const SizedBox(height: 10),
                _DeliverRow(
                  toTelegram: _toTelegram,
                  onChanged: (value) => setState(() => _toTelegram = value),
                ),
                const SizedBox(height: 20),
                _WhatItMayDo(schedule: _schedule),
                const SizedBox(height: 22),
                _DialogActions(
                  saving: _saving,
                  canSave: _canSave,
                  onCancel: () => Navigator.of(context).pop(),
                  onSave: () => _save(),
                  onTryNow: () => _save(runNow: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// When it runs, where — and what it's allowed to do while nobody is watching.
/// The last part is the one the user can't guess, so it isn't left out.
class _WhatItMayDo extends ConsumerWidget {
  const _WhatItMayDo({required this.schedule});

  final JobSchedule schedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final power = ref.watch(taskPowerProvider).value;
    final risky = power == TaskPower.fullAccess;

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
                'Runs ${schedule.describe().toLowerCase()}, on this computer, '
                'in your Projects folder.',
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

class _DialogTitle extends StatelessWidget {
  const _DialogTitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      'New scheduled task',
      style: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 21,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.12,
      ),
    );
  }
}
