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
  final said = _lastSaid(conversation);
  return said == null ? '' : firstLinePreview(said.text.trim());
}

/// How the turn behind that recap ended, so the tile can tint it.
///
/// [failure] is the chat's own error — the message the window is showing, so
/// the two screens blame the same thing. Otherwise the verdict comes out of the
/// message the recap was read from: a turn that ended with a step still
/// unaccounted for ([AgentActivityStatus.unknown]) was cut off rather than
/// finished, which is exactly what that status was added to record.
///
/// Its blind spot is worth naming: a turn stopped before it ran anything has no
/// steps to be unknown about, so it reads as [PanelRecapKind.done]. That is the
/// cheaper mistake — a plain line drawn plainly — and the alternative would be
/// inventing a "stopped" flag on the chat that nothing else needs.
PanelRecapKind panelRecapKindOf({
  required String? failure,
  required Conversation? conversation,
}) {
  if (failure != null && failure.trim().isNotEmpty) {
    return PanelRecapKind.failed;
  }
  final said = _lastSaid(conversation);
  if (said == null) return PanelRecapKind.done;
  final cutShort = said.parts.any(
    (part) =>
        part is TurnStep && part.step.status == AgentActivityStatus.unknown,
  );
  return cutShort ? PanelRecapKind.stopped : PanelRecapKind.done;
}

/// The last message the assistant actually said something in, or null.
///
/// One walk shared by the recap and its tint, so the line on the tile and the
/// colour behind it can never come from two different turns.
ChatMessage? _lastSaid(Conversation? conversation) {
  if (conversation == null) return null;
  for (final message in conversation.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    if (message.text.trim().isNotEmpty) return message;
  }
  return null;
}

/// The panel's view of [run]'s timeline — [TurnPart]s as [PanelTurnPart]s, in
/// the order they happened, capped to what a frame and a tile can carry.
///
/// Pure, and the only place the app's turn becomes the panel's. A step
/// contributes what the device draws a row from — its label, status, kind, the
/// tool's name, the argument and where it sits in the turn — and a passage
/// contributes its text. The step's *result* stays behind: the app holds it for
/// the transcript, and a 466px tile has nowhere to put it.
///
/// Takes the whole run rather than its parts because [t0] needs both ends of a
/// subtraction, and the turn's start is the run's ([panelTurnStartOf]). Passing
/// them separately would make it possible to measure one turn's steps against
/// another turn's clock.
///
/// A part with nothing to draw — a passage that is only whitespace, a step with
/// no label — is dropped rather than sent as a blank row.
List<PanelTurnPart> panelTurnPartsFor(AgentRun run) {
  final since = panelTurnStartOf(run);
  final drawn = <PanelTurnPart>[];
  for (final part in run.parts) {
    final mapped = _panelPart(part, since);
    if (mapped != null) drawn.add(mapped);
  }
  if (drawn.length <= kPanelTurnPartLimit) return drawn;
  return drawn.sublist(drawn.length - kPanelTurnPartLimit);
}

/// The agent's plan, as the panel draws it. Empty when it has none, which the
/// message then leaves out entirely.
List<PanelTurnTodo> panelTurnTodosFor(AgentRun run) {
  final todos = <PanelTurnTodo>[];
  for (final entry in run.plan) {
    final text = clipPanelText(entry.content.trim());
    if (text.isEmpty) continue;
    todos.add(PanelTurnTodo(text: text, status: _todoStatus(entry.status)));
  }
  return todos;
}

/// When the turn behind [run] began — what every step's `t0` is measured from.
///
/// [AgentRun.startedAt] whenever the turn came through [AgentRuns.reset], which
/// every agent send does. The earliest step stands in otherwise, so a feed that
/// was never started that way still reports a step's place *in its own
/// timeline* rather than the 56 years since the epoch.
DateTime? panelTurnStartOf(AgentRun run) {
  final started = run.startedAt;
  if (started != null) return started;
  DateTime? first;
  for (final part in run.parts) {
    if (part is! TurnStep) continue;
    final began = part.step.startedAt;
    if (began == null) continue;
    if (first == null || began.isBefore(first)) first = began;
  }
  return first;
}

/// A plan step's status in the three words a *todo* uses on the wire.
///
/// Written out rather than borrowed from [AgentActivityStatus], though two of
/// the words are spelled the same. The two vocabularies fail in opposite
/// directions: an unrecognised **step** is drawn as finished, because a spinner
/// left turning claims work is happening that isn't — while an unrecognised
/// **todo** is drawn as `pending`, because a tick claims work nobody has begun
/// is done. Sharing one enum is what made it tempting to send `unknown` here,
/// and `unknown` means "ran, but never reported back" — which a plan has no
/// equivalent of, and which the step rule would then draw as a finished item.
String _todoStatus(AgentPlanStatus status) => switch (status) {
  AgentPlanStatus.pending => 'pending',
  AgentPlanStatus.active => 'running',
  AgentPlanStatus.done => 'done',
};

PanelTurnPart? _panelPart(TurnPart part, DateTime? since) => switch (part) {
  TurnText(:final text) => _textPart(text),
  TurnStep(:final step) => _stepPart(step, since),
};

PanelTurnPart? _textPart(String text) {
  final clipped = clipPanelText(text.trim());
  return clipped.isEmpty ? null : PanelTurnPart.text(clipped);
}

PanelTurnPart? _stepPart(AgentActivity step, DateTime? since) {
  final label = clipPanelText(step.label.trim());
  if (label.isEmpty) return null;
  final arg = clipPanelText(step.request?.trim() ?? '');
  return PanelTurnPart.step(
    label: label,
    status: step.status.name,
    kind: step.kind.name,
    tool: step.tool,
    arg: arg.isEmpty ? null : arg,
    parent: step.parent,
    t0: _t0(step, since),
  );
}

/// Milliseconds from the turn's start to this step's, or null when either end
/// is unknown.
///
/// Never negative: a step stamped a hair before the run it belongs to (two
/// calls to [DateTime.now] a microsecond apart) would otherwise hand the device
/// a clock running backwards.
int? _t0(AgentActivity step, DateTime? since) {
  final began = step.startedAt;
  if (began == null || since == null) return null;
  final ms = began.difference(since).inMilliseconds;
  return ms < 0 ? 0 : ms;
}

/// [text] cut to [kPanelPartTextLimit], marked with an ellipsis so the tile
/// shows that there is more rather than a sentence that stops mid-word.
String clipPanelText(String text) {
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
  List<PanelTurnTodo> todos = const [],
}) {
  var shown = parts;
  var payload = PanelOutbound.turnParts(
    projectId: projectId,
    parts: shown,
    todos: todos,
  );
  while (shown.isNotEmpty && utf8.encode(payload).length > kPanelMaxPayload) {
    shown = shown.sublist(1);
    payload = PanelOutbound.turnParts(
      projectId: projectId,
      parts: shown,
      todos: todos,
    );
  }
  // The plan is the last thing to go, and only once dropping the timeline has
  // not been enough — an agent that wrote a plan of two hundred steps. Without
  // it the loop above can run out of parts and still hand back a payload the
  // frame will refuse, which is a throw rather than a message the panel misses.
  if (utf8.encode(payload).length <= kPanelMaxPayload) return payload;
  return PanelOutbound.turnParts(projectId: projectId, parts: shown);
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
  PanelTurnMirror({this.onTurnEnded});

  /// Called as a turn settles, with the chat it ended in.
  ///
  /// The hook the long-form `summary` hangs off. It fires here rather than
  /// being worked out again by the controller because *this* is where a turn
  /// ending is noticed — a second reading of the same moment would be free to
  /// disagree about when it happened, and the two would drift.
  final void Function(String projectId, Conversation? chat)? onTurnEnded;

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
    final holders = panelTurnHoldersOf(projects, chats);
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
      final run = runs[chatId] ?? AgentRun.empty;
      final parts = panelTurnPartsFor(run);
      final todos = panelTurnTodosFor(run);
      // Nothing to draw and nothing drawn yet — an empty timeline right behind
      // `turn.started` says nothing the panel doesn't already know. A plan on
      // its own is worth sending: an agent that lays out its steps before it
      // runs one has said something the tile can show.
      if (parts.isEmpty && todos.isEmpty && !_sent.containsKey(projectId)) {
        continue;
      }
      final payload = panelTurnPartsMessage(
        projectId: projectId,
        parts: parts,
        todos: todos,
      );
      if (_sent[projectId] == payload) continue;
      _sent[projectId] = payload;
      messages.add(payload);
    }
    return messages;
  }

  /// How the turn that was running in [chatId] ended.
  ///
  /// The chat's last error when it has one — the message the app itself shows,
  /// so the panel and the window blame the same thing — and otherwise the last
  /// line the assistant said. A chat deleted mid-turn settles with an empty
  /// recap: the tile must stop spinning either way.
  ///
  /// [panelRecapKindOf] makes the choice, so the tile's tint and the message
  /// the panel gets here can never say different things about one turn.
  String _settle(String projectId, String chatId, ChatSessionsState chats) {
    final chat = panelChatById(chats, chatId);
    final failure = chats.errorFor(chatId);
    onTurnEnded?.call(projectId, chat);
    return switch (panelRecapKindOf(failure: failure, conversation: chat)) {
      PanelRecapKind.failed => PanelOutbound.turnError(
        projectId: projectId,
        message: failure!.trim(),
      ),
      PanelRecapKind.done || PanelRecapKind.stopped => PanelOutbound.turnDone(
        projectId: projectId,
        recap: panelRecapOf(chat),
      ),
    };
  }
}

/// Which chat holds each project's turn right now, keyed by project.
///
/// Projects the app doesn't list are skipped: the panel was never sent a tile
/// for them, and a chat can outlive the project it was started in.
///
/// Shared rather than written twice. The panel speaks projects and the rest of
/// the app speaks chats, so *every* message going out has to make this hop —
/// turn state and permission questions alike — and a second copy of the rule
/// would be the one that stopped agreeing about which chat a tile is showing.
Map<String, String> panelTurnHoldersOf(
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

/// The conversation with [id], or null when it has been deleted under a turn.
Conversation? panelChatById(ChatSessionsState chats, String id) {
  for (final conversation in chats.conversations) {
    if (conversation.id == id) return conversation;
  }
  return null;
}
