import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One file the agent changed this session — enough to show the change and put it
/// back the way it was.
///
/// [before] is the file's contents before the agent's first edit to it, or null
/// when the agent created it (so undo deletes it). [after] is the latest
/// contents the agent wrote, kept so the review can diff before against after.
class AgentChange {
  const AgentChange({
    required this.path,
    required this.before,
    required this.after,
  });

  final String path;
  final String? before;
  final String after;

  /// True when the agent created this file (there was nothing before it).
  bool get isNew => before == null;

  /// The file's name, for a compact label.
  String get name => path.split(Platform.pathSeparator).last.split('/').last;

  AgentChange copyWith({String? after}) =>
      AgentChange(path: path, before: before, after: after ?? this.after);
}

/// The files the agent has changed and can still put back.
///
/// Every edit the agent makes — whether the user approved it or Full access let
/// it through — is recorded here with the file's original contents, so "the
/// agent just changed my files" always has an undo. Cleared when the user
/// switches conversation; the snapshots live only in memory, so this is a
/// same-session safety net, not a version history.
final agentChangesProvider =
    NotifierProvider<AgentChangesController, List<AgentChange>>(
      AgentChangesController.new,
    );

class AgentChangesController extends Notifier<List<AgentChange>> {
  @override
  List<AgentChange> build() => const [];

  /// Note that the agent changed [path] from [before] to [after]. The first
  /// [before] seen for a file wins, so undoing restores the pre-agent original
  /// even after several edits; [after] tracks the latest so the diff stays
  /// current. Relative paths are ignored — undo must write the right file, and
  /// only an absolute path names it unambiguously.
  void record({
    required String path,
    required String? before,
    required String after,
  }) {
    if (!_isAbsolute(path)) return;
    final existing = state.indexWhere((change) => change.path == path);
    if (existing >= 0) {
      state = [
        for (final change in state)
          if (change.path == path) change.copyWith(after: after) else change,
      ];
      return;
    }
    state = [...state, AgentChange(path: path, before: before, after: after)];
  }

  /// Put [change] back — restore its original contents, or delete it when the
  /// agent had created it — and drop it from the list. Returns null on success,
  /// else a line to show the user.
  Future<String?> revert(AgentChange change) async {
    final error = await _restore(change);
    if (error != null) return error;
    state = [
      for (final c in state)
        if (c.path != change.path) c,
    ];
    return null;
  }

  /// Undo every recorded change. Returns null when all succeeded, else how many
  /// couldn't be put back (the rest still were).
  Future<String?> revertAll() async {
    final failures = <String>[];
    final remaining = <AgentChange>[];
    for (final change in state) {
      final error = await _restore(change);
      if (error != null) {
        failures.add(change.name);
        remaining.add(change);
      }
    }
    state = remaining;
    if (failures.isEmpty) return null;
    return "Couldn't undo ${failures.length} file(s): ${failures.join(', ')}.";
  }

  /// Forget the recorded changes without touching any files — used when the
  /// user switches conversation, so one chat's changes don't haunt another.
  void clear() => state = const [];

  Future<String?> _restore(AgentChange change) async {
    try {
      final file = File(change.path);
      if (change.before == null) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsString(change.before!);
      }
      return null;
    } on Object catch (error) {
      return "Couldn't undo ${change.name}: $error";
    }
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
}
