import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import 'task_conversation_id.dart';

/// Remembers which scheduled tasks have a finished result the user hasn't opened
/// yet — the set of job ids the sidebar and the Scheduled list badge, so a run
/// that landed overnight isn't something you have to remember to go look for.
///
/// Persisted as `~/.grid/app/task_unread.json` (a plain list of job ids).
/// App-owned and lenient like the other app stores: an unreadable file reads as
/// "nothing unread", which quietly drops a badge rather than throwing.
class TaskUnreadStore {
  TaskUnreadStore({File? file}) : _file = file ?? GridPaths.taskUnreadFile;

  final File _file;

  Set<String> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return const {};
      return {
        for (final id in decoded)
          if (id is String && id.isNotEmpty) id,
      };
    } on Object {
      return const {};
    }
  }

  void save(Set<String> unread) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(unread.toList()),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final taskUnreadStoreProvider = Provider<TaskUnreadStore>(
  (ref) => TaskUnreadStore(),
);

/// The job ids whose latest result is unread. Set when a sweep delivers a new
/// run, cleared when the user opens that task's chat — the source the "new
/// results" badge reads, in the sidebar and on the Scheduled list.
final taskUnreadProvider = NotifierProvider<TaskUnreadController, Set<String>>(
  TaskUnreadController.new,
);

class TaskUnreadController extends Notifier<Set<String>> {
  @override
  Set<String> build() => ref.read(taskUnreadStoreProvider).load();

  /// Mark [jobIds] as having an unread result — skipping any whose chat is the
  /// one open right now, since a result you're already looking at isn't unread.
  void markUnread(Iterable<String> jobIds) {
    final openJob = jobIdOfTaskConversation(
      ref.read(chatSessionsProvider).activeId,
    );
    final next = {
      ...state,
      for (final id in jobIds)
        if (id != openJob) id,
    };
    if (next.length == state.length) return;
    _commit(next);
  }

  /// Clear the badge for [jobId] — the user opened its chat. A no-op when it
  /// wasn't unread, so it's cheap to call on every chat switch.
  void markRead(String jobId) {
    if (!state.contains(jobId)) return;
    _commit({...state}..remove(jobId));
  }

  void _commit(Set<String> next) {
    state = Set.unmodifiable(next);
    ref.read(taskUnreadStoreProvider).save(next);
  }
}
