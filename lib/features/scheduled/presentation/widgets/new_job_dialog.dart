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

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await ref
        .read(scheduledJobsProvider.notifier)
        .create(
          name: _name.text.trim(),
          prompt: _prompt.text.trim(),
          schedule: _schedule,
          toTelegram: _toTelegram,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
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
                const SizedBox(height: 18),
                _TaskField(
                  controller: _name,
                  label: 'Name',
                  hint: 'Daily digest',
                  autofocus: true,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 18),
                _CadenceRow(
                  cadence: _cadence,
                  onChanged: (value) => setState(() => _cadence = value),
                ),
                if (_cadence == JobCadence.weekly) ...[
                  const SizedBox(height: 12),
                  _WeekdayRow(
                    weekday: _weekday,
                    onChanged: (value) => setState(() => _weekday = value),
                  ),
                ],
                const SizedBox(height: 12),
                _TimeRow(time: _time, onPick: _pickTime),
                const SizedBox(height: 12),
                _DeliverRow(
                  toTelegram: _toTelegram,
                  onChanged: (value) => setState(() => _toTelegram = value),
                ),
                const SizedBox(height: 16),
                _WhatItMayDo(schedule: _schedule),
                const SizedBox(height: 22),
                _DialogActions(
                  saving: _saving,
                  canSave: _canSave,
                  onCancel: () => Navigator.of(context).pop(),
                  onSave: _save,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Runs ${schedule.describe().toLowerCase()}, on this computer, in '
          'your Projects folder.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.35,
            color: AppPalette.textSecondary,
          ),
        ),
        if (power != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                taskPowerIcon(power),
                size: 14,
                color: risky ? AppPalette.warn : AppPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  taskPowerDetail(power),
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: risky ? AppPalette.warn : AppPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
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
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.12,
      ),
    );
  }
}
