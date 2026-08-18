import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/hermes_permission_policy.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';
import 'panel_turn_mirror.dart';

/// What each answer is called, in the window's own words.
///
/// The panel and the desktop are two screens asking one question, so they say
/// it the same way (§5) — a card that reads "Allow once" in the window and
/// "Yes" on the panel is two questions as far as the person answering is
/// concerned.
const Map<AgentPermissionChoice, String> kPanelAnswerLabels = {
  AgentPermissionChoice.refuse: "Don't allow",
  AgentPermissionChoice.allowForChat: 'Allow in this chat',
  AgentPermissionChoice.allowOnce: 'Allow once',
};

/// The answers the panel may offer for [request], in the order to draw them.
///
/// Built from the agent's own options rather than a fixed pair: what it offers
/// varies, and a panel that assumes two would draw a button for an answer that
/// was never on the table. Each entry is one the app can *deliver* —
/// [optionIdForChoice] resolved it against this very request — so no button
/// here can turn into a silent no on the way back. That is also why the list is
/// not simply [AgentPermission.options] copied out: the agent's
/// `allow_always` is one this app never picks (it would outlive the setting
/// that allowed it), and offering it would put a button on the panel whose only
/// possible outcome is a refusal.
List<PanelQuestionOption> panelAnswersFor(AgentPermission request) {
  final answers = <PanelQuestionOption>[];
  final seen = <String>{};
  for (final entry in kPanelAnswerLabels.entries) {
    final optionId = optionIdForChoice(entry.key, request.options);
    if (optionId == null || !seen.add(optionId)) continue;
    answers.add(PanelQuestionOption(id: optionId, label: entry.value));
  }
  return answers;
}

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
  for (final choice in kPanelAnswerLabels.keys) {
    if (optionIdForChoice(choice, request.options) == optionId) return choice;
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
