import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/logging/app_log.dart';

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

/// The conversation the chat is showing, so the undo bar and its dialog speak
/// for that chat alone.
///
/// Published by the chat screen rather than derived here: which conversation is
/// open is the chat feature's fact, and the agent feature only needs to be told.
/// Null before any chat is on screen.
final agentChangesScopeProvider =
    NotifierProvider<AgentChangesScopeController, String?>(
      AgentChangesScopeController.new,
    );

class AgentChangesScopeController extends Notifier<String?> {
  @override
  String? build() => null;

  /// The user is now looking at [chatId] (null when no conversation is open).
  void show(String? chatId) {
    if (state == chatId) return;
    state = chatId;
  }
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
  final chatId = ref.watch(agentChangesScopeProvider);
  if (chatId == null) return const [];
  return ref.watch(agentChangesProvider)[chatId] ?? const [];
});

class AgentChangesController extends Notifier<Map<String, List<AgentChange>>> {
  /// The conversation whose agent turn is running — claimed by the chat that
  /// dispatched it. Agent turns run one at a time, so everything recorded until
  /// the next turn belongs to this chat, including edits that land after the
  /// user has moved on.
  String? _owner;

  @override
  Map<String, List<AgentChange>> build() => const {};

  /// The agent is about to work for [chatId]: file what it changes under that
  /// conversation.
  void attributeTo(String chatId) => _owner = chatId;

  /// Note that the agent changed [path] from [before] to [after]. The first
  /// [before] seen for a file wins, so undoing restores the pre-agent original
  /// even after several edits; [after] tracks the latest so the diff stays
  /// current. A leading `~` is expanded to the home folder first — Hermes reports
  /// the path the agent typed, and it routinely writes to `~/Downloads/...` —
  /// after which anything still not absolute is ignored, since only an absolute
  /// path lets undo write the right file back.
  void record({
    required String path,
    required String? before,
    required String after,
  }) {
    final chatId = _owner;
    if (chatId == null) {
      // Only a turn whose chat was deleted mid-flight gets here — an ordinary
      // one claims the turn before its sender can run. Filed under no
      // conversation the change would be shown by nothing and undoable from
      // nowhere, so leave a trace instead of dropping it in silence.
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
      return;
    }
    _put(chatId, [
      ...current,
      AgentChange(path: resolved, before: before, after: after),
    ]);
  }

  /// Put [change] back — restore its original contents, or delete it when the
  /// agent had created it — and drop it from the conversation on screen, the
  /// only one whose changes are ever offered. Returns null on success, else a
  /// line to show the user.
  Future<String?> revert(AgentChange change) async {
    final chatId = ref.read(agentChangesScopeProvider);
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
    final chatId = ref.read(agentChangesScopeProvider);
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
  /// conversation the user deleted, whose undo nothing can reach any more.
  ///
  /// A turn still running for that chat stops being recorded too: its edits
  /// would rebuild the entry that was just dropped, in a chat that no longer
  /// exists.
  void forget(String chatId) {
    if (_owner == chatId) _owner = null;
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
