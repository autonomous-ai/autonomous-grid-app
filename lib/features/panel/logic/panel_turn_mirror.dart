import 'dart:convert';

import '../../../core/text_preview.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/panel/panel_frame.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../agents/logic/agent_providers.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
import '../../projects/logic/project.dart';

/// How many of a turn's parts the panel is told about.
///
/// A frame's payload is capped at 8192 bytes (`docs/protocol.md` §1) and a turn
/// has no ceiling at all: an agent that opens three dozen files before it says a
/// word would blow the frame, and the link's answer to an over-long frame is to
/// drop it — so the whole turn would vanish rather than arrive shortened. The
/// **most recent** parts, because the panel is a live view: what the agent is
/// doing now is the thing a person glances at a 480px tile to see, and the
/// transcript in the app keeps the rest.
const int kPanelTurnPartLimit = 12;

/// How much of one part goes over the wire.
///
/// Twelve parts at this length is under 3 KB of JSON, which leaves the frame
/// budget honest even when every part is at the cap. It is also about as much
/// text as the tile can draw: a passage longer than this is scrolled off a
/// screen with no scrollbar.
const int kPanelPartTextLimit = 200;

/// Whether a turn is happening in the chat with [id].
///
/// The union of the two facts on purpose. [ChatSessionsState.agentRunningIn] is
/// the chat holding its project's agent lane; [ChatSessionsState.sendingFor] is
/// any turn in flight — including the second or so a turn spends being routed
/// before it runs, and a turn the grid answers directly (a picture, a computer
/// with no agent installed), which never takes a lane at all. Either alone
/// leaves a gap where the project is working and the panel says it is idle.
bool panelTurnInFlight(ChatSessionsState chats, String id) =>
    chats.sendingFor(id) || chats.agentRunningIn(id);

/// The last thing the assistant said in [conversation], cut to one line.
///
/// Empty when nothing has been said yet, which the panel messages leave out
/// rather than send as a blank.
String panelRecapOf(Conversation? conversation) {
  if (conversation == null) return '';
  for (final message in conversation.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    final text = message.text.trim();
    if (text.isNotEmpty) return firstLinePreview(text);
  }
  return '';
}

/// The panel's view of a turn's timeline — [TurnPart]s as [PanelTurnPart]s, in
/// the order they happened, capped to what a frame and a tile can carry.
///
/// Pure, and the only place the app's turn becomes the panel's. A step
/// contributes its label and status; a passage contributes its text. The step's
/// request and result stay behind: the app holds them for the transcript, and a
/// 480px tile draws a line and a spinner.
///
/// A part with nothing to draw — a passage that is only whitespace, a step with
/// no label — is dropped rather than sent as a blank row.
List<PanelTurnPart> panelTurnPartsFor(List<TurnPart> parts) {
  final drawn = <PanelTurnPart>[];
  for (final part in parts) {
    final mapped = _panelPart(part);
    if (mapped != null) drawn.add(mapped);
  }
  if (drawn.length <= kPanelTurnPartLimit) return drawn;
  return drawn.sublist(drawn.length - kPanelTurnPartLimit);
}

PanelTurnPart? _panelPart(TurnPart part) => switch (part) {
  TurnText(:final text) => _textPart(text),
  TurnStep(:final step) => _stepPart(step),
};

PanelTurnPart? _textPart(String text) {
  final clipped = _clip(text.trim());
  return clipped.isEmpty ? null : PanelTurnPart.text(clipped);
}

PanelTurnPart? _stepPart(AgentActivity step) {
  final label = _clip(step.label.trim());
  return label.isEmpty
      ? null
      : PanelTurnPart.step(label: label, status: step.status.name);
}

/// [text] cut to [kPanelPartTextLimit], marked with an ellipsis so the tile
/// shows that there is more rather than a sentence that stops mid-word.
String _clip(String text) {
  if (text.length <= kPanelPartTextLimit) return text;
  // Never cut a character in half — the same rule the stored transcript follows.
  // A lone surrogate is not valid UTF-8, and this string is about to be encoded
  // as some.
  final unit = text.codeUnitAt(kPanelPartTextLimit - 1);
  final end = (unit >= 0xD800 && unit <= 0xDBFF)
      ? kPanelPartTextLimit - 1
      : kPanelPartTextLimit;
  return '${text.substring(0, end)}…';
}

/// A `turn.parts` message for [projectId] that is guaranteed to fit one frame.
///
/// [kPanelTurnPartLimit] and [kPanelPartTextLimit] are the everyday rule; this
/// is the guarantee, and the two are not the same thing. A frame **refuses** a
/// payload over [kPanelMaxPayload] by throwing, and twelve parts of two hundred
/// characters is 2.4 KB of English and three times that in a language that
/// costs three bytes a character — so the arithmetic is an average, not a
/// bound. Dropping the message instead would lose the whole timeline over one
/// long line; dropping the *oldest* parts loses the least, for the same reason
/// the cap keeps the newest ones.
String panelTurnPartsMessage({
  required String projectId,
  required List<PanelTurnPart> parts,
}) {
  var shown = parts;
  var payload = PanelOutbound.turnParts(projectId: projectId, parts: shown);
  while (shown.isNotEmpty && utf8.encode(payload).length > kPanelMaxPayload) {
    shown = shown.sublist(1);
    payload = PanelOutbound.turnParts(projectId: projectId, parts: shown);
  }
  return payload;
}

/// Turns the app's live chat state into the messages that tell a panel what is
/// happening, and remembers what it has already said.
///
/// Stateful on purpose, and the state is entirely "what does the panel already
/// know": a turn's timeline is re-derived whole on every change (see
/// [PanelOutbound.turnParts]), so without a memory of the last payload the link
/// would carry the same 3 KB again for every streamed token. Nothing here is
/// app state — dropping the whole object loses nothing but that memory.
///
/// Keyed by **project**, because a project is what a tile is. Which chat inside
/// it holds the turn is the desktop's business.
class PanelTurnMirror {
  /// The chat holding each project's turn, as the panel last heard it.
  final Map<String, String> _holding = {};

  /// The last `turn.parts` payload sent per project, so an unchanged timeline
  /// is not sent twice.
  final Map<String, String> _sent = {};

  /// What to say after a change in chat state.
  List<String> onChange({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentRun> runs,
  }) =>
      _diff(projects: projects, chats: chats, runs: runs, partsOnStart: false);

  /// What to say to a panel that has just introduced itself.
  ///
  /// Everything is forgotten first: a panel that reboots — after a flash, after
  /// the cable is nudged — comes back knowing nothing, and a turn it was never
  /// told had started would reach it as a timeline for work it thinks isn't
  /// running.
  List<String> onAttach({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentRun> runs,
  }) {
    _holding.clear();
    _sent.clear();
    return _diff(
      projects: projects,
      chats: chats,
      runs: runs,
      partsOnStart: true,
    );
  }

  List<String> _diff({
    required List<Project> projects,
    required ChatSessionsState chats,
    required Map<String, AgentRun> runs,
    required bool partsOnStart,
  }) {
    final holders = _holdersOf(projects, chats);
    final messages = <String>[];

    // Settle first, so a project that hands its lane from one chat straight to
    // the next reads as one turn ending and another beginning rather than as a
    // timeline that suddenly changes its mind.
    for (final projectId in _holding.keys.toList()) {
      final held = _holding[projectId]!;
      if (holders[projectId] == held) continue;
      messages.add(_settle(projectId, held, chats));
      _holding.remove(projectId);
      _sent.remove(projectId);
    }

    for (final MapEntry(key: projectId, value: chatId) in holders.entries) {
      if (!_holding.containsKey(projectId)) {
        _holding[projectId] = chatId;
        messages.add(PanelOutbound.turnStarted(projectId));
        // Not the timeline, on this change. `ChatSessionsController.send`
        // commits the user's turn and *then* clears the chat's run feed, so at
        // the instant a turn starts that feed still holds the previous turn's
        // steps — sending it here would flash the last turn's commands under
        // the new question. The clearing arrives as its own change a moment
        // later, and so does every real part after it. [onAttach] is the
        // exception: nothing is starting there, the feed is already the
        // running turn's, and a panel that has just plugged in needs it.
        if (!partsOnStart) continue;
      }
      final parts = panelTurnPartsFor((runs[chatId] ?? AgentRun.empty).parts);
      // Nothing to draw and nothing drawn yet — an empty timeline right behind
      // `turn.started` says nothing the panel doesn't already know.
      if (parts.isEmpty && !_sent.containsKey(projectId)) continue;
      final payload = panelTurnPartsMessage(projectId: projectId, parts: parts);
      if (_sent[projectId] == payload) continue;
      _sent[projectId] = payload;
      messages.add(payload);
    }
    return messages;
  }

  /// Which chat holds each project's turn right now.
  ///
  /// Projects the app doesn't list are skipped: the panel was never sent a tile
  /// for them, and a chat can outlive the project it was started in.
  Map<String, String> _holdersOf(
    List<Project> projects,
    ChatSessionsState chats,
  ) {
    final known = {for (final project in projects) project.id};
    final holders = <String, String>{};
    for (final conversation in chats.live) {
      final projectId = conversation.projectId;
      if (projectId == null || !known.contains(projectId)) continue;
      if (!panelTurnInFlight(chats, conversation.id)) continue;
      // The chat actually running wins over one committed behind it. Turns are
      // serialized per project, so a second chat in the same folder is waiting
      // for the lane — and its (empty) timeline is not what is happening there.
      if (holders.containsKey(projectId) &&
          !chats.agentRunningIn(conversation.id)) {
        continue;
      }
      holders[projectId] = conversation.id;
    }
    return holders;
  }

  /// How the turn that was running in [chatId] ended.
  ///
  /// The chat's last error when it has one — the message the app itself shows,
  /// so the panel and the window blame the same thing — and otherwise the last
  /// line the assistant said. A chat deleted mid-turn settles with an empty
  /// recap: the tile must stop spinning either way.
  String _settle(String projectId, String chatId, ChatSessionsState chats) {
    final failure = chats.errorFor(chatId)?.trim();
    if (failure != null && failure.isNotEmpty) {
      return PanelOutbound.turnError(projectId: projectId, message: failure);
    }
    return PanelOutbound.turnDone(
      projectId: projectId,
      recap: panelRecapOf(_chatById(chats, chatId)),
    );
  }

  Conversation? _chatById(ChatSessionsState chats, String id) {
    for (final conversation in chats.conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }
}
