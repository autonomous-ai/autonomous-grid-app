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
  // What the user typed into the turn from the desktop is dropped rather than
  // mirrored: the wire has two kinds of part, text and step (see
  // `docs/panel-protocol.md`), and sending it as text would put the user's own
  // words on the device in the agent's voice. A third kind is a change both
  // ends have to agree on, and this one belongs to the desk the panel sits on
  // — not to the panel.
  TurnSaid() => null,
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

/// A `turn.parts` message for [chatId] that is guaranteed to fit one frame.
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
  required String chatId,
  required List<PanelTurnPart> parts,
  List<PanelTurnTodo> todos = const [],
}) {
  var shown = parts;
  var payload = PanelOutbound.turnParts(
    chatId: chatId,
    parts: shown,
    todos: todos,
  );
  while (shown.isNotEmpty && utf8.encode(payload).length > kPanelMaxPayload) {
    shown = shown.sublist(1);
    payload = PanelOutbound.turnParts(
      chatId: chatId,
      parts: shown,
      todos: todos,
    );
  }
  // The plan is the last thing to go, and only once dropping the timeline has
  // not been enough — an agent that wrote a plan of two hundred steps. Without
  // it the loop above can run out of parts and still hand back a payload the
  // frame will refuse, which is a throw rather than a message the panel misses.
  if (utf8.encode(payload).length <= kPanelMaxPayload) return payload;
  return PanelOutbound.turnParts(chatId: chatId, parts: shown);
}

/// How often a running turn's timeline is repeated to the panel.
///
/// Against the device's 25 s stale-busy sweep, so two beats can be missed
/// before a tile that is genuinely working is dropped. Not shorter: this is a
/// re-send of a payload the panel already has, and its only job is to be
/// recent.
const Duration kPanelTurnBeat = Duration(seconds: 10);

/// Turns the app's live chat state into the messages that tell a panel what is
/// happening, and remembers what it has already said.
///
/// Stateful on purpose, and the state is entirely "what does the panel already
/// know": a turn's timeline is re-derived whole on every change (see
/// [PanelOutbound.turnParts]), so without a memory of the last payload the link
/// would carry the same 3 KB again for every streamed token. Nothing here is
/// app state — dropping the whole object loses nothing but that memory.
///
/// Keyed by **chat**, because a chat is what a tile is. It was keyed by project
/// until 2026-08-18, which forced a rule for picking one chat to speak for a
/// project's whole timeline — and that rule was written when turns were
/// serialized per project. `bf462afc` let every chat in a project answer at
/// once, so the rule started dropping one of two live turns on the floor.
class PanelTurnMirror {
  /// [clock] is injected so [keepAlive] can be tested without waiting. One
  /// source for both the stamp and the comparison — reading `DateTime.now()`
  /// in one and taking the other from the caller is two clocks, and they
  /// disagree the moment anybody passes a fabricated time.
  PanelTurnMirror({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Turns that settled on the last pass, waiting for someone to close them out.
  ///
  /// **Collected rather than called back**, and the ordering is the reason. A
  /// turn that worked settles as `turn.summarizing`, and whoever writes the
  /// headline answers with the `turn.done` that ends it — so the callback must
  /// not run until the message it follows has actually gone. Called from inside
  /// `_settle` it fired first, and the panel received the end of the turn before
  /// it was told the turn was still being read. Drained by [drainEnded] after
  /// the caller has pushed what this pass produced.
  final _ended = <({String chatId, Conversation? chat})>[];

  /// The chats the panel has been told are running.
  final Set<String> _holding = {};

  /// The last `turn.parts` payload sent per chat, so an unchanged timeline is
  /// not sent twice.
  final Map<String, String> _sent = {};

  /// When each chat's timeline last went out, for [keepAlive].
  final Map<String, DateTime> _sentAt = {};

  /// The turns that settled since this was last called, and forget them.
  ///
  /// Call it AFTER pushing what the same pass returned: a turn that worked was
  /// announced as `turn.summarizing`, and each of these is owed the `turn.done`
  /// that follows it.
  List<({String chatId, Conversation? chat})> drainEnded() {
    final ended = [..._ended];
    _ended.clear();
    return ended;
  }

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
    _sentAt.clear();
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
    final running = panelRunningChatsOf(projects, chats);
    final messages = <String>[];

    // Settle first, so a chat that ends one turn and starts another in the same
    // pass reads as an ending followed by a beginning rather than as a timeline
    // that suddenly changes its mind.
    for (final chatId in _holding.toList()) {
      if (running.contains(chatId)) continue;
      messages.add(_settle(chatId, chats));
      _holding.remove(chatId);
      _sent.remove(chatId);
      _sentAt.remove(chatId);
    }

    for (final chatId in running) {
      if (!_holding.contains(chatId)) {
        _holding.add(chatId);
        // The beat's clock starts HERE, not at the first timeline. A turn that
        // has produced no steps yet — an agent thinking, or one long tool call
        // before it says anything — has nothing in `_sent`, and keepAlive's
        // "never sent" fallback then read as "just sent" and never fired. That
        // is precisely the turn this beat exists for, and it was the one turn it
        // could not save (seen on hardware 2026-08-18).
        _sentAt[chatId] = _clock();
        messages.add(PanelOutbound.turnStarted(chatId));
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
      if (parts.isEmpty && todos.isEmpty && !_sent.containsKey(chatId)) {
        continue;
      }
      final payload = panelTurnPartsMessage(
        chatId: chatId,
        parts: parts,
        todos: todos,
      );
      if (_sent[chatId] == payload) continue;
      _sent[chatId] = payload;
      _sentAt[chatId] = _clock();
      messages.add(payload);
    }
    return messages;
  }

  /// Say again what a running turn's timeline is, for any chat that has gone
  /// quiet.
  ///
  /// **The tile's liveness is per CHAT, and the link's heartbeat does not carry
  /// it.** The device clears a busy tile after 25 s without a frame ABOUT THAT
  /// TILE (`ui_prune_stale_busy`), and the only thing that stamps it is a
  /// `processing` — which is what a `turn.parts` becomes. Meanwhile this mirror
  /// deliberately sends nothing while the timeline is unchanged, or the link
  /// would carry 3 KB per streamed token.
  ///
  /// Those two rules meet badly in the middle of a real turn: an agent inside
  /// one long tool call, or a model thinking, produces no new parts for
  /// minutes. The app is working, the `ping` says the app is alive, and the
  /// panel still drops the tile back to the last turn's recap — reported from
  /// the desk on 2026-08-18. The summarizing beat covered the tail of a turn
  /// and nothing covered its body.
  ///
  /// Re-sending the SAME payload rather than inventing a lighter beat: it is
  /// what is true, it is what the panel would draw anyway, and it costs one
  /// frame per running chat per [after] — against a 25 s deadline, at most a
  /// few KB a minute on a cable that carries 8 KB firmware slices.
  List<String> keepAlive({required Duration after}) {
    final now = _clock();
    return [
      for (final chatId in _holding)
        if (now.difference(_sentAt[chatId] ?? now) >= after)
          // A turn that has produced nothing yet has no payload to repeat, and
          // still owns a tile that says it is working. An empty timeline is the
          // honest thing to repeat there.
          _stampAlive(chatId, now),
    ];
  }

  String _stampAlive(String chatId, DateTime now) {
    final payload =
        _sent[chatId] ??
        panelTurnPartsMessage(chatId: chatId, parts: const []);
    _sentAt[chatId] = now;
    return payload;
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
  /// How the turn that was running in [chatId] ended, as the panel is told it.
  ///
  /// A turn that WORKED does not end here — it hands over to
  /// [PanelTurnMirror.onTurnEnded], which writes the headline, and the panel is
  /// told `turn.summarizing` so its tile stays in the working state it is
  /// already in. Showing a placeholder recap for the few seconds that takes and
  /// then swapping it is worse than showing nothing: the intermediate state is
  /// not missing information, it is **wrong** information, and it is wrong on a
  /// screen someone is reading from across the room.
  ///
  /// A turn that FAILED ends immediately. The failure message *is* the outcome —
  /// there is nothing a model could add, and "Summarizing…" over a turn that
  /// already broke would delay the one thing worth saying.
  String _settle(String chatId, ChatSessionsState chats) {
    final chat = panelChatById(chats, chatId);
    final failure = chats.errorFor(chatId);
    switch (panelRecapKindOf(failure: failure, conversation: chat)) {
      case PanelRecapKind.failed:
        // Ends here, and is NOT queued for a headline. `turn.error` is already
        // terminal, and a `turn.done` behind it would be a second ending for one
        // turn — the tile would settle on a recap where it had just shown the
        // failure. Only what leaves as `turn.summarizing` is owed a close-out.
        return PanelOutbound.turnError(
          chatId: chatId,
          message: failure!.trim(),
        );
      case PanelRecapKind.done:
      case PanelRecapKind.stopped:
        _ended.add((chatId: chatId, chat: chat));
        return PanelOutbound.turnSummarizing(chatId);
    }
  }
}

/// Every chat with a turn in flight right now, in the order the panel lists
/// them.
///
/// Chats outside the projects the app lists are skipped: the panel was never
/// sent a tile for them, and a chat can outlive the project it was started in.
///
/// **This used to return one chat per project**, and picking that one was a
/// rule: "the chat actually running wins over one committed behind it, because
/// turns are serialized per project, so a second chat in the same folder is
/// waiting for the lane". `bf462afc` ("let every chat in a project answer at
/// once") deleted the premise and left the rule standing, so two live turns in
/// one folder overwrote each other and the panel drew whichever the iteration
/// order happened to reach last. One tile per chat is what makes the question
/// disappear rather than get a better answer.
Set<String> panelRunningChatsOf(
  List<Project> projects,
  ChatSessionsState chats,
) => {
  for (final chatId in panelTileChatsOf(projects, chats))
    if (panelTurnInFlight(chats, chatId)) chatId,
};

/// Every chat the panel has a tile for.
///
/// The one definition of "the panel knows about this chat", so the tiles, the
/// turns and the permission cards cannot disagree about what exists. Chats
/// outside the projects the app lists are skipped: no tile was ever sent for
/// them, and a chat can outlive the project it was started in.
Set<String> panelTileChatsOf(List<Project> projects, ChatSessionsState chats) {
  final known = {for (final project in projects) project.id};
  return {
    for (final conversation in chats.live)
      if (known.contains(conversation.projectId)) conversation.id,
  };
}

/// The conversation with [id], or null when it has been deleted under a turn.
Conversation? panelChatById(ChatSessionsState chats, String id) {
  for (final conversation in chats.conversations) {
    if (conversation.id == id) return conversation;
  }
  return null;
}
