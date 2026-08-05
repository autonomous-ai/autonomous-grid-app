import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// What a task's newest result actually said, in one line.
///
/// The Scheduled list knew a result had *arrived* long before it could say what
/// was in it: a row read "New results" and left the only way to find out — open
/// it — to the user, for every task, every morning. This is the line that lets
/// them skip the ones that don't matter.
class TaskResultDigest {
  const TaskResultDigest({required this.summary, required this.at});

  /// The answer's opening line (see `firstLinePreview`). May be empty when the
  /// run produced nothing — the row then says that rather than quoting silence.
  final String summary;

  /// When the run that produced it happened.
  final DateTime at;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'at': at.toIso8601String(),
  };

  /// Null for anything that isn't a digest this app wrote — a half-written file
  /// drops one row rather than blanking the whole list.
  static TaskResultDigest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null) return null;
    return TaskResultDigest(summary: '${raw['summary'] ?? ''}', at: at);
  }
}

/// Remembers each task's newest result headline, as `~/.grid/app/task_inbox.json`.
///
/// App-owned and lenient like the other app stores: an unreadable file reads as
/// "no headlines yet", which costs a line of detail rather than the screen.
class TaskInboxStore {
  TaskInboxStore({File? file}) : _file = file ?? GridPaths.taskInboxFile;

  final File _file;

  Map<String, TaskResultDigest> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): ?TaskResultDigest.fromJson(entry.value),
      };
    } on Object {
      return const {};
    }
  }

  void save(Map<String, TaskResultDigest> digests) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in digests.entries) entry.key: entry.value.toJson(),
      }),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final taskInboxStoreProvider = Provider<TaskInboxStore>(
  (ref) => TaskInboxStore(),
);

/// The newest result headline per task id. Written by the delivery sweep, read
/// by the Scheduled list.
final taskInboxProvider =
    NotifierProvider<TaskInboxController, Map<String, TaskResultDigest>>(
      TaskInboxController.new,
    );

class TaskInboxController extends Notifier<Map<String, TaskResultDigest>> {
  @override
  Map<String, TaskResultDigest> build() =>
      ref.read(taskInboxStoreProvider).load();

  /// Record what [jobId]'s latest run said. Replaces any older headline — the
  /// row shows the newest result, not a history.
  void record(String jobId, TaskResultDigest digest) {
    final next = {...state, jobId: digest};
    state = Map.unmodifiable(next);
    ref.read(taskInboxStoreProvider).save(next);
  }

  /// Forget [jobId] — its task is gone, and a headline for a task that no longer
  /// exists would outlive it in the file forever.
  void forget(String jobId) {
    if (!state.containsKey(jobId)) return;
    final next = {...state}..remove(jobId);
    state = Map.unmodifiable(next);
    ref.read(taskInboxStoreProvider).save(next);
  }
}
