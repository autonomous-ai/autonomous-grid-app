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

/// One question the panel has been shown: which chat it belongs to, and the id
/// it will echo back.
typedef PanelQuestion = ({String id, String chatId});

/// Keeps the panel's permission cards in step with the window's, and remembers
/// which chat each one came from.
///
/// Stateful for the same reason [PanelTurnMirror] is: the app's permissions are
/// a map that is rebuilt on every change, and without a memory of what the
/// panel was already shown the same card would go out again on every keystroke
/// elsewhere in the app. The memory is also the only thing that can answer "who
/// asked this?" when the panel replies — the reply carries the app's own opaque
/// id and nothing else.
///
/// Keyed by **project**, because a question is drawn over a tile.
class PanelQuestionMirror {
  /// The question each project's panel card is showing.
  final Map<String, PanelQuestion> _asked = {};

  /// What to say after the permissions, the chats or the projects moved.
  List<String> onChange({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentPermission> permissions,
  }) {
    final holders = panelTurnHoldersOf(projects, chats);
    final messages = <String>[];

    // Cancel first, so a project whose agent answers one question and asks the
    // next in the same breath reads as one card closing and another opening
    // rather than as a card that changed its mind.
    for (final projectId in _asked.keys.toList()) {
      final asked = _asked[projectId]!;
      final chatId = holders[projectId];
      final live = chatId == asked.chatId ? permissions[chatId] : null;
      if (live != null && '${live.id}' == asked.id) continue;
      _asked.remove(projectId);
      messages.add(
        PanelOutbound.questionCancel(projectId: projectId, id: asked.id),
      );
    }

    for (final MapEntry(key: projectId, value: chatId) in holders.entries) {
      final request = permissions[chatId];
      if (request == null) continue;
      final id = '${request.id}';
      if (_asked[projectId]?.id == id) continue;
      _asked[projectId] = (id: id, chatId: chatId);
      messages.add(_ask(projectId, request));
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

  /// The chat a panel answer belongs to, or null when nothing is waiting on
  /// that id — the two surfaces race by design, and the loser is discarded
  /// silently rather than reported.
  String? chatFor(String projectId, String id) {
    final asked = _asked[projectId];
    return asked != null && asked.id == id ? asked.chatId : null;
  }

  String _ask(String projectId, AgentPermission request) {
    // The path for a file edit: the panel draws one line under the summary, and
    // for an edit the thing worth reading is which file, not the diff — a 466px
    // tile cannot show a diff and the window already is.
    final detail = clipPanelText(
      (request.command ?? request.path ?? '').trim(),
    );
    return PanelOutbound.question(
      projectId: projectId,
      id: '${request.id}',
      summary: clipPanelText(request.summary.trim()),
      command: detail.isEmpty ? null : detail,
      options: panelAnswersFor(request),
    );
  }
}
