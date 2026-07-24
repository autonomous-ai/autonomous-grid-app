import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import 'cron_output.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';
import 'scheduled_jobs_controller.dart';

/// The conversation a task's results land in. One per task, so a daily digest
/// reads as a thread rather than a pile of unrelated chats.
String taskConversationId(String jobId) => 'task-$jobId';

/// A result as it reads in the chat: when the task ran, then what it found.
///
/// The stamp isn't decoration — three mornings of the same digest are otherwise
/// indistinguishable, and a result from a run the user missed would look like it
/// just arrived. The answer only ([cronOutputBody]), not the job-id/schedule
/// metadata Hermes wraps it in — the stamp above already carries the timing.
String taskResultMessage(CronOutput run) =>
    '*Ran ${jobTimeLabel(run.at)}*\n\n${cronOutputBody(run.text)}';

/// How often the app looks for runs that have finished.
///
/// The scheduler is Hermes's, not the app's: it runs jobs whether the app is open
/// or not, and simply leaves the result in a file. So the app has to come back and
/// look — there's nothing to push it.
const Duration kTaskSweepInterval = Duration(seconds: 30);

/// Overridable so tests don't wait on a real clock.
final taskSweepIntervalProvider = Provider<Duration>(
  (ref) => kTaskSweepInterval,
);

/// Remembers the last run of each task that was put into Chat, so a result is
/// delivered once — not again on every launch, and not again every 30 seconds.
///
/// Persisted as `~/.grid/app/task_delivery.json`. App-owned and lenient like the
/// other app stores: an unreadable file reads as "nothing delivered yet", which
/// re-delivers rather than silently dropping a result the user never saw.
class TaskDeliveryStore {
  TaskDeliveryStore({File? file}) : _file = file ?? GridPaths.taskDeliveryFile;

  final File _file;

  Map<String, DateTime> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String &&
              DateTime.tryParse('${entry.value}') != null)
            entry.key as String: DateTime.parse('${entry.value}'),
      };
    } on Object {
      return const {};
    }
  }

  void save(Map<String, DateTime> delivered) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in delivered.entries)
          entry.key: entry.value.toIso8601String(),
      }),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final taskDeliveryStoreProvider = Provider<TaskDeliveryStore>(
  (ref) => TaskDeliveryStore(),
);

/// Carries finished scheduled-task results into the Chat tab.
///
/// Hermes runs the tasks and writes each result to a file — that's all `--deliver
/// local` means, and left there the user would never see it. This watches for new
/// results and delivers them into the task's own chat, so "the answer is waiting
/// when you come back" is actually true.
final taskDeliveryProvider =
    NotifierProvider<TaskDeliveryController, List<String>>(
      TaskDeliveryController.new,
    );

class TaskDeliveryController extends Notifier<List<String>> {
  Timer? _timer;
  bool _sweeping = false;

  /// The ids of tasks whose results have arrived since the app started — what the
  /// sidebar could badge. Empty until something lands.
  @override
  List<String> build() {
    ref.onDispose(_stop);
    return const [];
  }

  /// Start watching. Called once, from the shell — not from `build`, so nothing
  /// is mutated while the app is still building its first frame.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      ref.read(taskSweepIntervalProvider),
      (_) => unawaited(sweep()),
    );
    unawaited(sweep());
  }

  /// Collect every result that hasn't been delivered yet, and put it in the
  /// task's chat. Safe to call at any time; overlapping sweeps are dropped.
  Future<void> sweep() async {
    final cron = ref.read(hermesCronServiceProvider);
    if (cron == null || _sweeping) return;
    _sweeping = true;
    try {
      final jobs = await ref.read(scheduledJobsProvider.future);
      final delivered = {...ref.read(taskDeliveryStoreProvider).load()};
      final arrived = <String>[];

      for (final job in jobs) {
        final last = await _deliver(job, cron, delivered[job.id]);
        if (last == null) continue;
        delivered[job.id] = last;
        arrived.add(job.id);
      }

      if (arrived.isEmpty) return;
      ref.read(taskDeliveryStoreProvider).save(delivered);
      state = [...state, ...arrived];
    } on Object {
      // A scheduler that can't be read is the Scheduled screen's problem to
      // report; a background sweep must not take the app down with it.
      return;
    } finally {
      _sweeping = false;
    }
  }

  /// Deliver [job]'s results newer than [since] into its chat. Returns the time
  /// of the newest one delivered, or null when there was nothing new.
  Future<DateTime?> _deliver(
    ScheduledJob job,
    HermesCronService cron,
    DateTime? since,
  ) async {
    final runs = await cron.readOutputs(job.id);
    final fresh = [
      for (final run in runs)
        if (since == null || run.at.isAfter(since)) run,
    ];
    if (fresh.isEmpty) return null;

    final chat = ref.read(chatSessionsProvider.notifier);
    for (final run in fresh) {
      chat.deliverFromAgent(
        id: taskConversationId(job.id),
        title: job.name,
        text: taskResultMessage(run),
        at: run.at,
      );
    }
    return fresh.last.at;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
