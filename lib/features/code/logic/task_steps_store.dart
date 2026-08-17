import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import 'task_event_lines.dart';

/// What a finished task did, kept so it is still there tomorrow.
///
/// A task is minutes of tool calls and a sentence of prose, and until this
/// existed only the sentence survived: the live feed lived in memory behind an
/// auto-disposing provider, so closing the task threw the run away and the
/// transcript kept the summary alone (issue #30).
///
/// App-owned, like `project_tasks.json` beside it — the relay's own task row
/// has no field for this, and it is re-parsed from the wire on every poll.
/// One file per task, for the same reason chats get one each: a single map
/// would be rewritten in full every time any task ended.
///
/// Nothing prunes these yet. A task cannot be deleted — cancelling one leaves
/// it in the project's history, where its record still belongs — so the folder
/// only grows with the work actually done, at a few kilobytes a run. Leaving a
/// project is the one case that strands files; **TODO(BE):** clear a project's
/// runs when its tasks stop being listed.
class TaskStepsStore {
  TaskStepsStore({Directory? directory})
    : _dir = directory ?? GridPaths.taskStepsDir;

  final Directory _dir;

  /// The most lines kept for one task.
  ///
  /// Generous rather than tight: this is the record of a run somebody may read
  /// weeks later, and the view tails it anyway. A line is a tool name and a
  /// path, so four thousand of them is a few hundred kilobytes at worst.
  static const int maxLines = 4000;

  File _fileFor(String taskId) => File('${_dir.path}/$taskId.json');

  /// Write what [lines] show of task [taskId], keeping the last [maxLines].
  ///
  /// Called once, when the run ends. Never throws: a run whose record could not
  /// be written is still a run the user watched, and taking the screen down
  /// over it would be the app punishing them for a full disk.
  Future<void> save(String taskId, List<TaskLine> lines) async {
    if (lines.isEmpty) return;
    final kept = lines.length <= maxLines
        ? lines
        : lines.sublist(lines.length - maxLines);
    try {
      await _dir.create(recursive: true);
      await _fileFor(taskId).writeAsString(
        jsonEncode({
          'dropped': lines.length - kept.length,
          'lines': [
            for (final line in kept)
              {'seq': line.seq, 'text': line.text, 'tone': line.tone.name},
          ],
        }),
      );
    } on IOException {
      return;
    }
  }

  /// What was kept of task [taskId] — empty when nothing was, which is every
  /// task that ran before this existed.
  Future<StoredTaskRun> load(String taskId) async {
    final file = _fileFor(taskId);
    try {
      if (!await file.exists()) return const StoredTaskRun();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const StoredTaskRun();
      final raw = decoded['lines'];
      final dropped = decoded['dropped'];
      return StoredTaskRun(
        lines: [
          if (raw is List)
            for (final entry in raw) ?_line(entry),
        ],
        dropped: dropped is int && dropped > 0 ? dropped : 0,
      );
    } on Object {
      // A half-written or hand-edited file reads as "nothing kept". The task's
      // result text is still there, which is exactly where this feature found
      // the world.
      return const StoredTaskRun();
    }
  }

  static TaskLine? _line(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final text = raw['text'];
    if (seq is! int || text is! String || text.isEmpty) return null;
    return (
      seq: seq,
      text: text,
      tone: TaskLineTone.values.firstWhere(
        (tone) => tone.name == raw['tone'],
        orElse: () => TaskLineTone.note,
      ),
    );
  }
}

/// A run read back off disk: its lines, and how many older ones the cap cut.
class StoredTaskRun {
  const StoredTaskRun({this.lines = const [], this.dropped = 0});

  final List<TaskLine> lines;

  /// Steps that happened before the ones kept. Said on screen rather than
  /// silently missing — a record that starts mid-run reads as a run that
  /// started there.
  final int dropped;

  bool get isEmpty => lines.isEmpty;
}

final taskStepsStoreProvider = Provider<TaskStepsStore>(
  (ref) => TaskStepsStore(),
);

/// What was kept of a finished task's run.
///
/// A family future rather than a stream: the file is written once, when the
/// task ends, so there is nothing to watch.
final taskStepsProvider = FutureProvider.family<StoredTaskRun, String>(
  (ref, taskId) => ref.read(taskStepsStoreProvider).load(taskId),
);
