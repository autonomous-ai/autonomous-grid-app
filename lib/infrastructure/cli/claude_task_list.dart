/// Claude Code's task list, as the CLI keeps it on disk.
///
/// The plan a Claude chat shows is built from `TaskCreate` and `TaskUpdate`
/// as they stream past (`ClaudeStreamParser`), but a turn is a new process and
/// a new parser, and the list is not the turn's — it is the session's, and
/// outlives every turn in it. Over a month of this machine's sessions, 99 of
/// the `-p` lane's 336 task updates changed a task an *earlier* turn had made,
/// and each was passed over because this turn had never seen that task made.
///
/// Claude's own VS Code panel meets the same problem by keeping its process
/// alive, and when a session is reopened, by replaying every message of it
/// through the same reducer (`loadFromMessages`). Here the CLI's own store
/// stands in for the replay: it writes each task to
/// `<config>/tasks/<list id>/<n>.json`, and the list id is the session id —
/// 43 of 43 lists on this machine are named after theirs, sub-agents' tasks
/// included, and `--resume` keeps the id. So a resumed turn starts from what
/// is on disk, and the stream's deltas land on it.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';

/// One task as the CLI stored it — the fields the plan draws.
typedef ClaudeTask = ({String id, String subject, String status});

/// The config directory a turn's CLI reads and writes: `CLAUDE_CONFIG_DIR`
/// when the turn's [environment] sets it, else `~/.claude`.
String claudeConfigDir(Map<String, String> environment) {
  final named = environment['CLAUDE_CONFIG_DIR']?.trim() ?? '';
  if (named.isNotEmpty) return named;
  return '${environment['HOME'] ?? GridPaths.userHome}/.claude';
}

/// The list a turn of [sessionId] works on: the one `CLAUDE_CODE_TASK_LIST_ID`
/// names when the turn's [environment] sets it — the CLI's own first choice —
/// else the session's.
String claudeTaskListId(Map<String, String> environment, String sessionId) {
  final named = environment['CLAUDE_CODE_TASK_LIST_ID']?.trim() ?? '';
  return named.isNotEmpty ? named : sessionId;
}

/// Where the CLI keeps list [listId] under [configDir]. The rule is its own:
/// `<config>/tasks/<id>`, with anything outside `[A-Za-z0-9_-]` in the id
/// replaced by `-`.
String claudeTaskListDir({required String configDir, required String listId}) =>
    '$configDir/tasks/${listId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-')}';

/// One task file, or null when it holds nothing the plan can show.
ClaudeTask? parseClaudeTask(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  return switch (decoded) {
    {
      'id': final String id,
      'subject': final String subject,
      'status': final String status,
    }
        when subject.trim().isNotEmpty =>
      (id: id, subject: subject.trim(), status: status),
    _ => null,
  };
}

/// Every task in [dir], in the order the CLI numbered them.
///
/// Empty when there is no list — a first turn has none — or it can't be read:
/// the stream still builds the plan from what it sees, and this only lets it
/// recognise what came before. The CLI's own bookkeeping (`.lock`,
/// `.highwatermark`) is skipped.
Future<List<ClaudeTask>> readClaudeTaskList(String dir) async {
  final List<FileSystemEntity> entries;
  try {
    entries = await Directory(dir).list().toList();
  } on FileSystemException {
    return const [];
  }
  final tasks = <ClaudeTask>[];
  for (final entry in entries) {
    final name = entry.uri.pathSegments.last;
    if (entry is! File || name.startsWith('.') || !name.endsWith('.json')) {
      continue;
    }
    try {
      if (parseClaudeTask(await entry.readAsString()) case final task?) {
        tasks.add(task);
      }
    } on FileSystemException {
      // Deleted between the listing and the read — the CLI removes a deleted
      // task's file — so it is not part of the list any more.
    }
  }
  return tasks..sort(_byNumber);
}

int _byNumber(ClaudeTask a, ClaudeTask b) {
  final x = int.tryParse(a.id);
  final y = int.tryParse(b.id);
  return x != null && y != null ? x.compareTo(y) : a.id.compareTo(b.id);
}

/// The list a new turn carries on with — none once every task is done.
///
/// Claude Code's own screen clears a list whose every task is completed: it
/// resets it on disk when it hides it. Under `-p` there is no screen to do
/// that, so a finished list stays; carried into the next turn it would sit,
/// all ticked, above whatever the agent plans next.
List<ClaudeTask> claudeTasksToCarry(List<ClaudeTask> tasks) =>
    tasks.every((task) => task.status == 'completed') ? const [] : tasks;
