import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../agents/logic/agent_permission_answers.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';
import 'panel_turn_mirror.dart';

/// The answers the panel may offer for [request], in the order to draw them —
/// the same ones, in the same words, as every other surface that asks (see
/// [permissionAnswersFor]).
List<PanelQuestionOption> panelAnswersFor(AgentPermission request) => [
  for (final answer in permissionAnswersFor(request))
    PanelQuestionOption(id: answer.optionId, label: answer.label),
];

/// Which answer an echoed [optionId] stands for, or null when it names nothing
/// this request offered — a card the panel drew before the question moved on.
///
/// The exact inverse of [panelAnswersFor], and deliberately so: the panel sends
/// back an id the app itself chose, so reading it is a lookup rather than a
/// guess about what the user meant.
AgentPermissionChoice? panelChoiceForAnswer(
  String optionId,
  AgentPermission request,
) {
  for (final answer in permissionAnswersFor(request)) {
    if (answer.optionId == optionId) return answer.choice;
  }
  return null;
}

/// Keeps the panel's permission cards in step with the window's.
///
/// Stateful for the same reason [PanelTurnMirror] is: the app's permissions are
/// a map that is rebuilt on every change, and without a memory of what the
/// panel was already shown the same card would go out again on every keystroke
/// elsewhere in the app.
///
/// Keyed by **chat**, because a question is drawn over a tile and a tile is a
/// chat. It was keyed by project until 2026-08-18, which needed a second map to
/// answer "who asked this?" when the panel replied — the panel named a project
/// and the permission lived on a chat. The panel now names the chat, and both
/// the map and the question disappear.
class PanelQuestionMirror {
  /// The id of the question each chat's panel card is showing.
  final Map<String, String> _asked = {};

  /// What to say after the permissions, the chats or the projects moved.
  List<String> onChange({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentPermission> permissions,
  }) {
    final tiles = panelTileChatsOf(projects, chats);
    final messages = <String>[];

    // Cancel first, so a chat whose agent answers one question and asks the
    // next in the same breath reads as one card closing and another opening
    // rather than as a card that changed its mind.
    for (final chatId in _asked.keys.toList()) {
      final live = tiles.contains(chatId) ? permissions[chatId] : null;
      if (live != null && '${live.id}' == _asked[chatId]) continue;
      final id = _asked.remove(chatId)!;
      messages.add(PanelOutbound.questionCancel(chatId: chatId, id: id));
    }

    for (final MapEntry(key: chatId, value: request) in permissions.entries) {
      // No tile, nowhere to draw it. A question for a chat the panel was never
      // sent would be a card with no context on a 466px screen.
      if (!tiles.contains(chatId)) continue;
      final id = '${request.id}';
      if (_asked[chatId] == id) continue;
      _asked[chatId] = id;
      messages.add(_ask(chatId, request));
    }
    return messages;
  }

  /// What to say to a panel that has just introduced itself.
  ///
  /// Everything is forgotten first: a panel that reboots comes back with no
  /// cards on screen, and cancelling one it has never seen would be the app's
  /// half of a conversation the panel is not having.
  List<String> onAttach({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentPermission> permissions,
  }) {
    _asked.clear();
    return onChange(projects: projects, chats: chats, permissions: permissions);
  }

  /// Whether the panel is still showing question [id] for [chatId].
  ///
  /// False once the window has answered it: the two surfaces race by design,
  /// and the loser is discarded silently rather than reported.
  bool isAsking(String chatId, String id) => _asked[chatId] == id;

  String _ask(String chatId, AgentPermission request) {
    // The path for a file edit: the panel draws one line under the summary, and
    // for an edit the thing worth reading is which file, not the diff — a 466px
    // tile cannot show a diff and the window already is.
    final detail = clipPanelText(
      (request.command ?? request.path ?? '').trim(),
    );
    return PanelOutbound.question(
      chatId: chatId,
      id: '${request.id}',
      summary: clipPanelText(request.summary.trim()),
      command: detail.isEmpty ? null : detail,
      options: panelAnswersFor(request),
    );
  }
}
