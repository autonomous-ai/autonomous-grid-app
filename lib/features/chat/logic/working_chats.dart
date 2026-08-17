import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_sessions_controller.dart';

/// One chat that is answering right now — a row of "Working now".
///
/// Flattened out of [ChatSessionsState] rather than read from it row by row, so
/// the list can carry its own equality: see [WorkingChats].
class WorkingChat {
  const WorkingChat({
    required this.id,
    required this.title,
    required this.projectId,
    required this.agentId,
    required this.startedAt,
    required this.queued,
  });

  /// The conversation this turn belongs to — what opening the row selects.
  final String id;
  final String title;

  /// The project the chat lives in, or null for a chat outside every project.
  /// An id, not a name: naming it is the view's job, through the project store.
  final String? projectId;

  /// The agent answering, or null when the grid itself is (a picture, or a
  /// computer with no agent installed).
  final String? agentId;

  /// When this turn went out. Null only in the window between a turn being
  /// committed and dispatched, so the row counts from "now" rather than lying.
  final DateTime? startedAt;

  /// How many follow-ups the user has typed behind this turn.
  final int queued;

  @override
  bool operator ==(Object other) =>
      other is WorkingChat &&
      other.id == id &&
      other.title == title &&
      other.projectId == projectId &&
      other.agentId == agentId &&
      other.startedAt == startedAt &&
      other.queued == queued;

  @override
  int get hashCode =>
      Object.hash(id, title, projectId, agentId, startedAt, queued);
}

/// Every chat answering right now, longest-running first.
///
/// **A class, not a bare list, for its `==`.** This is derived from the whole
/// chat state, which changes on every streamed token — and a `List` compares by
/// identity, so a plain list would wake every watcher (the top bar, the ⌘K
/// palette) on each token to hand them the same rows back. Nothing here moves
/// while a turn streams, so value equality means those watchers rebuild when a
/// chat starts or stops and at no other time.
class WorkingChats {
  const WorkingChats(this.rows);

  static const empty = WorkingChats([]);

  final List<WorkingChat> rows;

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;

  /// The chats in this set, for a caller that only needs membership — the
  /// palette, which lists them above its own results.
  Set<String> get ids => {for (final row in rows) row.id};

  @override
  bool operator ==(Object other) {
    if (other is! WorkingChats || other.rows.length != rows.length) {
      return false;
    }
    for (var i = 0; i < rows.length; i++) {
      if (other.rows[i] != rows[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(rows);
}

/// The chats answering in [state], longest-running first.
///
/// Longest first because that is the one a person came looking for: a turn that
/// has been going twenty minutes is the one they have lost track of, and a list
/// ordered by it doesn't reshuffle under the pointer the way "most recently
/// started" would every time another chat answers.
///
/// Pure, so the ordering and what each row carries are tested rather than
/// eyeballed through an overlay.
WorkingChats buildWorkingChats(ChatSessionsState state) {
  final rows = <WorkingChat>[
    for (final chat in state.conversations)
      if (state.sendingFor(chat.id))
        WorkingChat(
          id: chat.id,
          title: chat.title,
          projectId: chat.projectId,
          agentId: state.agentRunningId(chat.id),
          startedAt: state.turnStartFor(chat.id),
          queued: state.queuedFor(chat.id).length,
        ),
  ];
  // A turn with no start time yet sorts last rather than first: it is the
  // youngest thing here, not the oldest.
  rows.sort((a, b) {
    final left = a.startedAt;
    final right = b.startedAt;
    if (left == null || right == null) return left == null ? 1 : -1;
    return left.compareTo(right);
  });
  return WorkingChats(List.unmodifiable(rows));
}

/// What is answering across the whole app, whichever screen the user is on.
///
/// App-wide on purpose: the value of this list is the turn running in the
/// project you are *not* looking at. Chats are keyed by conversation throughout
/// the controller, so a project is only a field on a row here — the top bar
/// counts them all, and each row names the project it belongs to.
final workingChatsProvider = Provider<WorkingChats>(
  (ref) => buildWorkingChats(ref.watch(chatSessionsProvider)),
);
