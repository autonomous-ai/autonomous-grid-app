import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_task_policy.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_select_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_status.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../chat/logic/conversation.dart';
import '../../../network/logic/node_display.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/playground_models.dart';
import '../../../projects/logic/project.dart';
import '../../logic/job_schedule.dart';
import '../../logic/job_suggestions.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';
import '../../logic/task_conversation_id.dart';
import '../../logic/task_destination.dart';
import '../../logic/task_models.dart';
import '../../logic/task_power_controller.dart';
import '../../logic/task_runner.dart';
import 'scheduled_pill_choice.dart';
import 'task_power_bar.dart';

part 'new_job_dialog_actions.dart';
part 'new_job_dialog_fields.dart';
part 'new_job_dialog_schedule.dart';
part 'new_job_dialog_summary.dart';

/// Asks for the three things a scheduled task needs — a name, what to do, and
/// when — and saves it with Hermes's scheduler.
///
/// No cron in sight: the user picks "every weekday at 08:00" and the app writes
/// the expression. Opened blank from "New task", or prefilled from a suggestion.
///
/// Pass [project] to scope the task to a folder: it runs there (so it can read
/// that project's files) and shows under that project's rail, rather than in the
/// shared workspace with no project.
Future<void> showNewJobDialog(
  BuildContext context, {
  JobSuggestion? from,
  Project? project,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x66000000),
  builder: (_) => _NewJobDialog(suggestion: from, project: project),
);

/// The same form over a task that already exists — the way to fix a typo, move
/// the time or say more about the job without deleting it and losing every
/// result it has produced.
Future<void> showEditJobDialog(BuildContext context, ScheduledJob job) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (_) => _NewJobDialog(job: job),
    );

class _NewJobDialog extends ConsumerStatefulWidget {
  const _NewJobDialog({this.suggestion, this.project, this.job});

  final JobSuggestion? suggestion;

  /// The task being changed, or null when this is a new one. It decides what the
  /// form is seeded with, what the buttons say, and which write it makes.
  final ScheduledJob? job;

  /// The project this task belongs to, or null for a workspace-wide task.
  final Project? project;

  @override
  ConsumerState<_NewJobDialog> createState() => _NewJobDialogState();
}

class _NewJobDialogState extends ConsumerState<_NewJobDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late JobCadence _cadence;
  late TimeOfDay _time;
  late Set<int> _days;
  bool _saving = false;

  /// The model the task is pinned to. Null until the grid's list has landed —
  /// [_ModelRow] then shows what it can, and [_model] resolves the default.
  String? _picked;

  /// The task's own schedule expression when this form can't draw it —
  /// [_ForeignScheduleNote] then says so rather than letting the default read as
  /// what the task runs on. Null in every other case.
  String? _foreignSchedule;

  /// Who answers it, and where the answer lands. Both are settled on create:
  /// changing them on a saved task would rewrite the script and move results
  /// away from the thread they have been arriving in, so the form only offers
  /// them on a new one.
  TaskRunner _runner = TaskRunner.hermes;
  TaskDestination _destination = const TaskOwnChat();

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    final seed = widget.suggestion;
    // An existing task is seeded from itself; a new one from a suggestion, or
    // from the default hour if it hasn't got one.
    final stored = job == null ? null : parseJobSchedule(job.cron);
    final schedule =
        stored ??
        seed?.schedule ??
        const JobSchedule(cadence: JobCadence.everyDay, hour: 9, minute: 0);
    _name = TextEditingController(text: job?.name ?? seed?.name ?? '');
    _prompt = TextEditingController(text: job?.prompt ?? seed?.prompt ?? '');
    _picked = job?.model;
    _cadence = schedule.cadence;
    _time = TimeOfDay(hour: schedule.hour, minute: schedule.minute);
    _days = schedule.days;
    if (job != null && stored == null) _foreignSchedule = job.cron;
    // A task made inside a project answers into that project unless the user
    // moves it — the rail it will show up in is the one they opened this from.
    final project = widget.project;
    if (job == null && project != null) {
      _destination = TaskProjectDestination(project.id);
    }
    if (job != null) _destination = parseTaskDeliver(job.deliver);
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
    days: _days,
  );

  /// Where the task will run, as a phrase [_WhatItMayDo] drops into its
  /// sentence — null while editing.
  ///
  /// A saved task's folder isn't part of what the app reads back out of Hermes,
  /// and an edit doesn't move it. Saying nothing is the honest half of the
  /// sentence; naming "your Projects folder" over a task that has been reading a
  /// project all along would be the app inventing an answer it doesn't have.
  String? get _location {
    if (widget.job != null) return null;
    final project = widget.project;
    return project == null ? 'in your Projects folder' : 'in "${project.name}"';
  }

  /// The model this task will be pinned to, out of [options]: the user's pick
  /// while it's still on offer, else the default for what the grid serves.
  ///
  /// A task being made *inside* a project starts on that project's model, the
  /// same one its chats run — a task set up in a folder is about that folder,
  /// and offering the app's model there would quietly pin it to something the
  /// user last used somewhere else.
  ///
  /// Resolved from a list the build already watched rather than read from a
  /// provider here — this is also what `Schedule it` sends, and `ref.watch`
  /// outside `build` is not allowed.
  String _modelIn(List<PlaygroundModelOption> options) {
    final picked = _picked;
    if (picked != null && options.any((option) => option.id == picked)) {
      return picked;
    }
    return defaultTaskModel(
      options,
      widget.project?.model ?? ref.read(chatPrefsProvider).model,
    );
  }

  /// Empty means the grid serves nothing the assistant can use — [_ModelRow]
  /// says so, and there's nothing to pin a task to. A scripted runner answers on
  /// its own sign-in, so it is savable on a grid serving nothing at all.
  bool _canSave(String model) =>
      !_saving &&
      _name.text.trim().isNotEmpty &&
      _prompt.text.trim().isNotEmpty &&
      (model.isNotEmpty || _runner.isScripted);

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
      _days = example.schedule.days;
    });
  }

  /// Save it on [model], and — when [runNow] — kick off one run immediately so
  /// the user can see what it produces before trusting it to a schedule. Either
  /// way the new task is opened in the pane behind the dialog.
  Future<void> _save(String model, {bool runNow = false}) async {
    setState(() => _saving = true);
    final result = await ref
        .read(scheduledJobsProvider.notifier)
        .create(
          name: _name.text.trim(),
          prompt: _prompt.text.trim(),
          schedule: _schedule,
          model: model,
          runner: _runner,
          destination: _destination,
          workdir: widget.project?.path,
          projectId: widget.project?.id,
          runNow: runNow,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      ToastScope.show(
        context,
        ToastSpec(message: result.error!, severity: ToastSeverity.error),
      );
      return;
    }
    if (result.id != null) {
      ref.read(selectedJobIdProvider.notifier).select(result.id);
    }
    if (runNow) {
      // In-progress, not an outcome — the answer hasn't landed yet.
      ToastScope.show(
        context,
        const ToastSpec(
          message: 'Running it now — the answer lands in a moment.',
          severity: ToastSeverity.info,
        ),
      );
    }
    Navigator.of(context).pop();
  }

  /// Write the form back onto [job]. The dialog stays open on a failure, with
  /// what the user typed still in it — closing it would take the edit with it.
  Future<void> _saveEdit(ScheduledJob job, String model) async {
    setState(() => _saving = true);
    final error = await ref
        .read(scheduledJobsProvider.notifier)
        .edit(
          id: job.id,
          name: _name.text.trim(),
          prompt: _prompt.text.trim(),
          schedule: _schedule,
          model: model,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ToastScope.show(
        context,
        ToastSpec(message: error, severity: ToastSeverity.error),
      );
      return;
    }
    ToastScope.show(
      context,
      const ToastSpec(
        message: 'Task updated.',
        severity: ToastSeverity.success,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Watched once, here, and handed down: the row draws from it, the resolved
    // model rides into `create`, and nothing reads a provider outside build.
    final options = taskModelOptions(ref.watch(playgroundModelsProvider));
    final model = _modelIn(options);
    final job = widget.job;
    final runners = [
      for (final runner in TaskRunner.values)
        if (ref.watch(agentInstalledProvider(runner.agent))) runner,
    ];
    // A task's own chats are not somewhere to deliver *into* — they are what
    // the default already makes. Newest first, and capped: this is a picker for
    // "the conversation I was just in", not a second chat list.
    final chats = [
      for (final chat in ref.watch(chatSessionsProvider).conversations)
        if (jobIdOfTaskConversation(chat.id) == null && !chat.isArchived) chat,
    ].take(kTaskDestinationChats).toList();
    final projects = ref.watch(projectsProvider);
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
                _DialogTitle(editing: job != null),
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
                // Examples are a way into a blank form; over a task that already
                // says something, "start from an example" only offers to
                // overwrite it.
                if (job == null) ...[
                  const SizedBox(height: 10),
                  _ExampleRow(onPick: _applyExample),
                ],
                const SizedBox(height: 22),
                const _GroupLabel('When it runs'),
                const SizedBox(height: 10),
                if (_foreignSchedule case final expression?) ...[
                  _ForeignScheduleNote(expression: expression),
                  const SizedBox(height: 10),
                ],
                _CadenceRow(
                  cadence: _cadence,
                  onChanged: (value) => setState(() => _cadence = value),
                ),
                if (_cadence == JobCadence.chosenDays) ...[
                  const SizedBox(height: 10),
                  _WeekdayRow(
                    days: _days,
                    onChanged: (value) => setState(() => _days = value),
                  ),
                ],
                // An interval cadence repeats through the day — there's no one
                // time to pick, so the time row would only mislead.
                if (!_cadence.isInterval) ...[
                  const SizedBox(height: 12),
                  _TimeRow(time: _time, onPick: _pickTime),
                ],
                const SizedBox(height: 22),
                // Only on a new task: see [_runner].
                if (job == null && runners.length > 1) ...[
                  const _GroupLabel('Which assistant runs it'),
                  const SizedBox(height: 10),
                  _RunnerRow(
                    runner: _runner,
                    installed: runners,
                    onChanged: (value) => setState(() => _runner = value),
                  ),
                  const SizedBox(height: 22),
                ],
                // A scripted task answers on its own agent's sign-in, so this
                // grid's models have no say in it — the row would be a choice
                // that changes nothing.
                if (!_runner.isScripted) ...[
                  const _GroupLabel('Which model runs it'),
                  const SizedBox(height: 10),
                  _ModelRow(
                    options: options,
                    model: model,
                    onChanged: (value) => setState(() => _picked = value),
                  ),
                  const SizedBox(height: 22),
                ],
                if (job == null) ...[
                  const _GroupLabel('Where the answer goes'),
                  const SizedBox(height: 10),
                  _DestinationRow(
                    destination: _destination,
                    chats: chats,
                    projects: projects,
                    onChanged: (value) => setState(() => _destination = value),
                  ),
                ],
                const SizedBox(height: 20),
                _WhatItMayDo(schedule: _schedule, location: _location),
                const SizedBox(height: 22),
                _DialogActions(
                  saving: _saving,
                  canSave: _canSave(model),
                  saveLabel: job == null ? 'Schedule it' : 'Save changes',
                  onCancel: () => Navigator.of(context).pop(),
                  onSave: () =>
                      job == null ? _save(model) : _saveEdit(job, model),
                  // "Try it now" belongs to a task that doesn't exist yet. The
                  // saved one already has Run now on its own screen.
                  onTryNow: job == null
                      ? () => _save(model, runNow: true)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
