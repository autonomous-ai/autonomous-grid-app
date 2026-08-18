import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/file_changes.dart';
import 'agent_chat_scope.dart';

/// One file the agent changed in a conversation — enough to show the change and
/// put it back the way it was.
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

/// The files the agent has changed, per conversation, and can still put back.
///
/// Every edit the agent makes — whether the user approved it or Full access let
/// it through — is recorded with the file's original contents, so "the agent
/// just changed my files" always has an undo. Keyed by the chat whose turn made
/// it: an agent keeps working after the user moves to another conversation, and
/// that other chat must neither claim the change nor offer to undo work the user
/// can't see there. The snapshots live only in memory, so this is a same-run
/// safety net, not a version history.
final agentChangesProvider =
    NotifierProvider<AgentChangesController, Map<String, List<AgentChange>>>(
      AgentChangesController.new,
    );

/// What the agent changed in the conversation on screen — what the bar counts
/// and the dialog lists. Empty for a chat whose agent hasn't touched anything.
final visibleAgentChangesProvider = Provider<List<AgentChange>>((ref) {
  final chatId = ref.watch(agentChatScopeProvider);
  if (chatId == null) return const [];
  return ref.watch(agentChangesProvider)[chatId] ?? const [];
});

/// The files the agent touched in the **most recent turn** of the conversation
/// on screen, absolute paths.
///
/// A conversation's changes pile up across every turn it has run; this is the
/// last one alone — which is what "what did it just do?" means, and what the
/// Review surface offers as its narrowest scope. Empty before the first turn
/// makes an edit.
final lastTurnAgentPathsProvider = Provider<Set<String>>((ref) {
  final chatId = ref.watch(agentChatScopeProvider);
  if (chatId == null) return const {};
  final changes = ref.watch(agentChangesProvider)[chatId] ?? const [];
  final from = ref.watch(agentChangesProvider.notifier).turnStartIn(chatId);
  return {for (final change in changes.skip(from)) change.path};
});

class AgentChangesController extends Notifier<Map<String, List<AgentChange>>> {
  /// How many changes each conversation already held when its current turn
  /// started — the line between "this turn" and everything before it. Kept
  /// beside the list rather than in it so nothing about undo changes shape.
  final Map<String, int> _turnStart = {};

  /// Conversations the user deleted. A turn still running for one keeps
  /// reporting edits, and recording them would rebuild the entry that was just
  /// dropped — in a chat nothing can show or undo from any more. Ids are never
  /// reused, so remembering them costs a string apiece.
  final Set<String> _forgotten = {};

  @override
  Map<String, List<AgentChange>> build() => const {};

  /// [chatId] is starting an agent turn: mark where this turn's changes begin.
  ///
  /// Which chat a change belongs to is carried by the caller ([record]), not
  /// latched here — turns run at the same time in different projects, and a
  /// single "current owner" filed one chat's edits under whichever chat had
  /// started a turn most recently.
  void beginTurn(String chatId) =>
      _turnStart[chatId] = _changesIn(chatId).length;

  /// Where [chatId]'s current turn started in its change list. Clamped, because
  /// undoing a change shortens the list under the mark.
  int turnStartIn(String chatId) {
    final start = _turnStart[chatId] ?? 0;
    final length = _changesIn(chatId).length;
    return start > length ? length : start;
  }

  /// Note that [chatId]'s agent changed [path] from [before] to [after]. The
  /// first [before] seen for a file wins, so undoing restores the pre-agent
  /// original even after several edits; [after] tracks the latest so the diff
  /// stays current. A leading `~` is expanded to the home folder first — Hermes
  /// reports the path the agent typed, and it routinely writes to
  /// `~/Downloads/...` — after which anything still not absolute is ignored,
  /// since only an absolute path lets undo write the right file back.
  ///
  /// [chatId] comes from the turn that made the edit, so an edit landing after
  /// the user has moved on — or while another project's agent is working — is
  /// still filed under the chat that asked for it.
  void record({
    required String chatId,
    required String path,
    required String? before,
    required String after,
  }) {
    if (_forgotten.contains(chatId)) return;
    if (chatId.isEmpty) {
      // A send with no conversation behind it (nothing in the app does this
      // today). Filed under no chat the change would be shown by nothing and
      // undoable from nowhere, so leave a trace instead of dropping it silently.
      ref
          .read(appLogProvider)
          .failure('agent', 'file change with no chat to file it under: $path');
      return;
    }
    final resolved = expandHome(path, GridPaths.userHome);
    if (!_isAbsolute(resolved)) return;
    final current = _changesIn(chatId);
    if (current.any((change) => change.path == resolved)) {
      _put(chatId, [
        for (final change in current)
          if (change.path == resolved)
            change.copyWith(after: after)
          else
            change,
      ]);
    } else {
      _put(chatId, [
        ...current,
        AgentChange(path: resolved, before: before, after: after),
      ]);
    }
    _announce(resolved);
  }

  /// Tell the rest of the app that a file on disk has moved on, so anything
  /// showing it re-reads rather than going on drawing the version from before
  /// the edit.
  void _announce(String path) =>
      ref.read(fileChangesProvider.notifier).touch([path]);

  /// Put [change] back — restore its original contents, or delete it when the
  /// agent had created it — and drop it from the conversation on screen, the
  /// only one whose changes are ever offered. Returns null on success, else a
  /// line to show the user.
  Future<String?> revert(AgentChange change) async {
    final chatId = ref.read(agentChatScopeProvider);
    if (chatId == null) return null;
    final error = await _restore(change);
    if (error != null) return error;
    _put(chatId, [
      for (final c in _changesIn(chatId))
        if (c.path != change.path) c,
    ]);
    return null;
  }

  /// Undo every change recorded in the conversation on screen. Returns null when
  /// all succeeded, else how many couldn't be put back (the rest still were).
  Future<String?> revertAll() async {
    final chatId = ref.read(agentChatScopeProvider);
    if (chatId == null) return null;
    final failures = <String>[];
    final remaining = <AgentChange>[];
    for (final change in _changesIn(chatId)) {
      final error = await _restore(change);
      if (error != null) {
        failures.add(change.name);
        remaining.add(change);
      }
    }
    _put(chatId, remaining);
    if (failures.isEmpty) return null;
    return "Couldn't undo ${failures.length} file(s): ${failures.join(', ')}.";
  }

  /// Forget [chatId]'s recorded changes without touching any files — for a
  /// conversation the user deleted, whose undo nothing can reach any more. A
  /// turn still running for it stops being recorded too (see [_forgotten]).
  void forget(String chatId) {
    _forgotten.add(chatId);
    _turnStart.remove(chatId);
    _drop(chatId);
  }

  List<AgentChange> _changesIn(String chatId) =>
      state[chatId] ?? const <AgentChange>[];

  void _put(String chatId, List<AgentChange> changes) {
    // Undoing the last one leaves the chat with nothing to show, but its turn
    // may still be running — drop the entry, not the chat's claim on what the
    // agent writes next.
    if (changes.isEmpty) {
      _drop(chatId);
      return;
    }
    state = {...state, chatId: List.unmodifiable(changes)};
  }

  void _drop(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = {
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
    };
  }

  Future<String?> _restore(AgentChange change) async {
    try {
      final file = File(change.path);
      if (change.before == null) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsString(change.before!);
      }
      // Undo writes to disk as surely as the agent did, so it announces itself
      // the same way — otherwise the panel keeps showing the edit that was just
      // taken back.
      _announce(change.path);
      return null;
    } on Object catch (error) {
      return "Couldn't undo ${change.name}: $error";
    }
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
}

/// Expands a leading `~` to [home] so `~/Downloads/x.txt` names a real, absolute
/// file. Hermes reports the path the agent typed verbatim and it routinely uses
/// `~` for the home folder; left as-is the change would go unrecorded (no undo),
/// and undoing it would write a literal `~` folder. A path that isn't
/// `~`-anchored is returned unchanged.
String expandHome(String path, String home) {
  if (path == '~') return home;
  if (path.startsWith('~/')) return '$home${path.substring(1)}';
  return path;
}

/// How long the "what the assistant changed" bar lingers after the last change
/// before it hides itself, so it reads as a notice rather than a fixture parked
/// over the composer for the rest of the conversation.
const Duration kAgentChangesAutoHide = Duration(seconds: 10);

/// Overridable so tests don't sit through the ten-second countdown.
final agentChangesAutoHideProvider = Provider<Duration>(
  (ref) => kAgentChangesAutoHide,
);

/// Whether the bar summarising [visibleAgentChangesProvider] is on screen.
///
/// The bar is a transient notice, not a permanent fixture: it appears when the
/// agent touches a file in the conversation on screen, hides itself after
/// [agentChangesAutoHideProvider], and can be waved away by hand. Hiding it never
/// undoes anything — the snapshots outlive the bar, so a later change raises it
/// again over the whole set. Opening another conversation drops it (that chat has
/// its own changes, or none), and coming back to one with changes still pending
/// raises it again over them.
final agentChangesBarProvider =
    NotifierProvider<AgentChangesBarController, bool>(
      AgentChangesBarController.new,
    );

class AgentChangesBarController extends Notifier<bool> {
  Timer? _hideTimer;

  @override
  bool build() {
    ref.onDispose(_cancelTimer);
    // The bar mirrors the change list it summarises — a change shows it and
    // restarts the countdown, an emptied list drops it. Switching conversation
    // moves that list too, so the same listener is what hides the bar on the way
    // out and raises it again on the way back. Reading the data from here, rather
    // than the undo store pushing to us, keeps that store unaware of how (or
    // whether) its contents are shown.
    ref.listen(visibleAgentChangesProvider, (_, next) {
      next.isEmpty ? _hide() : _show();
    });
    // Whatever the open chat already holds when the bar first mounts — usually
    // empty, since the composer builds before the agent has touched anything.
    return ref.read(visibleAgentChangesProvider).isNotEmpty;
  }

  /// Hide the bar now without undoing anything: the snapshots stay recorded, so a
  /// later change brings it back over the full set.
  void dismiss() => _hide();

  void _show() {
    _cancelTimer();
    state = true;
    _hideTimer = Timer(ref.read(agentChangesAutoHideProvider), _hide);
  }

  void _hide() {
    _cancelTimer();
    if (state) state = false;
  }

  void _cancelTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }
}
