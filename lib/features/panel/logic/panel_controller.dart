import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/stt_client.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/panel/panel_firmware_provider.dart';
import '../../../infrastructure/panel/panel_link.dart';
import '../../../infrastructure/panel/panel_link_provider.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../infrastructure/state/panel_recap_store.dart';
import '../../../shared/app_info.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../agents/logic/agent_permissions.dart';
import '../../agents/logic/agent_providers.dart';
import '../../agents/logic/auto_agent.dart';
import '../../auth/logic/session_controller.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
import '../../playground/logic/playground_models.dart';
import '../../projects/logic/project.dart';
import '../../projects/logic/selected_project.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import 'panel_firmware_updater.dart';
import 'panel_chat_mirror.dart';
import 'panel_question_mirror.dart';
import 'panel_scroll.dart';
import 'panel_summary_writer.dart';
import 'panel_turn_mirror.dart';
import 'panel_voice.dart';
import 'panel_voice_router.dart';
import '../../chat/logic/chat_title.dart';

/// The app's side of the conversation with a Grid Panel.
///
/// Answering is all it does. The panel runs nothing — no model, no agent, no
/// file — so every message it sends is a question about state this app already
/// keeps, and the answer is read back out of the same providers the window
/// renders. That is deliberate: a second reader of `~/.grid` would give two
/// truths that disagree, and the symptom ("the panel says one thing and the
/// window another") is a miserable bug to chase.
final panelControllerProvider = Provider<PanelController>((ref) {
  final controller = PanelController(ref);
  // A turn is **pushed**, not asked for: the panel has to show work as it
  // happens, and it cannot poll a 480px tile into being live. Listened to here
  // rather than from a second subscriber on the send stream — that stream has
  // exactly one listener (`chat_sessions_send.dart`), and a second one would be
  // a second reading of the same turn, free to disagree with the window's.
  //
  // Two providers because a turn moves in two places: the chat's send state
  // says a turn is happening, and the run feed says what it has done so far.
  ref.listen(chatSessionsProvider, (_, _) {
    controller.mirrorTurns();
    // And the TILES, because a tile is a chat: its title, its model and its
    // very existence live in this provider. Without this a model picked in the
    // window reached the panel only if something else happened to rebuild the
    // list — a project edited, or a headline written — which is minutes later
    // or never.
    //
    // Coalesced rather than immediate: this provider moves on every streamed
    // token, and rebuilding a hundred tiles into JSON per token to discover
    // that none of them changed is work nobody asked for. The mirror already
    // drops what has not changed; this keeps it from being asked fifty times a
    // second.
    controller.scheduleChatsMirror();
  });
  ref.listen(agentRunsProvider, (_, _) => controller.mirrorTurns());
  // The window moved to another chat — the carousel follows it there. Watched
  // as its own narrow selector rather than off the whole chat state, so a
  // streaming reply cannot make this fire: `activeId` changes when somebody
  // switches chats and at no other time.
  ref.listen(
    chatSessionsProvider.select((chats) => chats.activeId),
    (_, chatId) => controller.followWindow(chatId),
  );
  // A question is the one thing on this link the panel can answer *instead of*
  // the window, so it has to arrive there as fast as it arrives here — and,
  // more importantly, leave as fast. Whichever surface answers first cancels
  // the other, and every route out of a permission (either surface, the expiry
  // timer, the turn ending) empties this same map, so one listener covers them
  // all rather than four call sites remembering to say so.
  ref.listen(agentPermissionsProvider, (_, _) => controller.mirrorQuestions());
  // The tiles move on their own too. Without this a project created, renamed or
  // deleted on the desktop reached a plugged-in panel only if it happened to
  // ask again — which it does once, on waking.
  ref.listen(sortedProjectsProvider, (_, _) => controller.mirrorChats());
  // And when a turn's headline is written down: the tile carries the remembered
  // one, so the list is only as current as this store. The mirror dedups by
  // payload, so a turn that changed nothing the panel draws still sends nothing.
  ref.listen(panelRecapsProvider, (_, _) => controller.mirrorChats());
  ref.onDispose(controller.stop);
  return controller;
});

/// Answers the panel over [panelLinkProvider].
class PanelController {
  PanelController(this._ref);

  final Ref _ref;
  StreamSubscription<PanelInbound>? _sub;
  StreamSubscription<List<int>>? _audioSub;

  /// What the panel has already been told about turns in flight.
  final _turns = PanelTurnMirror();

  /// What the panel has already been told about permission questions.
  final _questions = PanelQuestionMirror();

  /// What the panel has already been told about the tiles.
  final _tiles = PanelChatMirror();

  /// Says the app is still here, on the cadence the panel measures absence
  /// against.
  Timer? _heartbeat;

  /// One per turn whose headline is being written, saying the tile should keep
  /// working.
  ///
  /// Held here as well as in the write's own `finally` because the write may
  /// never finish: a model that hangs leaves a periodic timer running for as long
  /// as the process lives, and in a test that outlives its container it is a
  /// pending timer at teardown. A set rather than a field because two projects
  /// can finish a turn at the same moment.
  final _summarizing = <Timer>{};

  /// Whether a panel has introduced itself on this link.
  ///
  /// The only evidence this side has that anyone is reading. [PanelPort.send]
  /// already drops bytes when nothing is attached, so this is not about the
  /// wire — it is about not spending a model call (and the user's tokens, and a
  /// line in the Debug tab) writing a summary for a screen that is not there.
  bool _greeted = false;

  /// Audio arriving between `voice.begin` and `voice.end`, or null when nobody
  /// is speaking.
  PanelVoiceCapture? _voice;

  /// Closes a capture the panel never closed itself.
  Timer? _voiceOpen;

  /// Transcripts the panel has been shown but not yet placed, by route id.
  ///
  /// A guess is not dispatched until `voice.confirm` names where it goes, so
  /// the words have to wait somewhere, and it cannot be on the panel: it sends
  /// back a route id, not the sentence.
  final _guessed = <String, ({String chatId, String text})>{};

  /// Route ids, unique within a session — which is all they need to be. They
  /// correlate a `voice.confirm` with the transcript it answers, and a panel
  /// that reboots in between has forgotten the transcript anyway.
  int _routes = 0;

  /// The panel this session is talking to, as its last `hello` described it.
  String _mac = '';
  String _firmwareVersion = '';

  /// A firmware offer held back because the machine was busy, retried when the
  /// last turn lands.
  PanelHello? _deferredOffer;

  /// Which firmware version each panel reported immediately before this session
  /// finished writing an image to it.
  ///
  /// The guard against a reflash loop: if a panel comes back from an update
  /// still reporting the version it had, offering again would flash it again,
  /// forever. It also names the only cause — the device's `hello.fw` and the
  /// version inside the image it was given disagree — in the log.
  final _flashed = <String, String>{};

  /// Image versions this session already tried to hand a panel and could not.
  ///
  /// Without this, a failing update retries on every `hello` — every fifteen
  /// seconds, for as long as the cable is in. That is not a quiet retry: the
  /// panel erases a flash slot before it answers an offer, so the loop spends
  /// erase cycles on the user's hardware to re-attempt something that has no
  /// reason to behave differently a second time. Nothing about the next `hello`
  /// changes what went wrong.
  ///
  /// Keyed by MAC, because two panels can be plugged in and one failing says
  /// nothing about the other. Session-scoped on purpose — replugging or
  /// restarting the app is a deliberate act and gets a fresh attempt.
  final _refused = <String, String>{};

  PanelFirmwareUpdater? _updater;

  /// Start answering. Safe to call twice — the second call is a no-op rather
  /// than a second subscription answering everything twice.
  ///
  /// Wired *before* the port is opened, not after: the panel says `hello` the
  /// moment it sees the port, and [PanelLink.messages] is a broadcast stream,
  /// so a message with no listener is dropped rather than buffered. A listener
  /// attached a frame late would miss the handshake and the link would sit
  /// there looking connected and silent.
  void listen() {
    final link = _ref.read(panelLinkProvider);
    _sub ??= link.messages.listen(_answer);
    // Audio arrives on its own stream and is subscribed to for the whole
    // session rather than only between begin and end: both are broadcast
    // streams with no buffer, so a subscription attached when `voice.begin`
    // lands would miss whatever chunks were already in flight behind it — the
    // first syllable of every sentence.
    _audioSub ??= link.audio.listen(_onAudio);
    // Started here rather than on `hello`, because the silence this fills is
    // the app's: over a cable there is nothing to disconnect, so an app that
    // has quit and an app with nothing to say look identical from the panel.
    // Empty on purpose — it says "still here" and re-sends no state, which is
    // what keeps a link idle through a long turn.
    _heartbeat ??= Timer.periodic(kPanelHeartbeat, (_) {
      _ref.read(panelLinkProvider).send(PanelOutbound.ping());
      // The `ping` above says the APP is alive. It says nothing about any one
      // tile, and the device times those out separately — 25 s without a frame
      // about a chat and it drops that tile back to the last recap, however
      // busy the machine is. A turn spends minutes inside a single tool call
      // without changing its timeline, so this is the beat that covers the body
      // of a turn the way `turn.summarizing` covers its tail.
      final alive = _turns.keepAlive(after: kPanelTurnBeat);
      if (alive.isNotEmpty) {
        // Logged on purpose, and it is evidence rather than noise: a tile that
        // drops back to its last recap mid-turn leaves NOTHING in this log
        // today, so the first question — did the app say anything about that
        // chat in the gap? — had no answer. At most one line per 10s per
        // running chat.
        _log.info('panel', 'Said again that ${alive.length} turn(s) are live');
        _push(alive);
      }
    });
  }

  /// Stop answering. The link and the port are released by their own providers.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _audioSub?.cancel();
    _audioSub = null;
    _voiceOpen?.cancel();
    _voiceOpen = null;
    _chatsPending?.cancel();
    _chatsPending = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _voice = null;
    _greeted = false;
    _deferredOffer = null;
    _updater?.reset();
    _updater = null;
  }

  Future<void> _answer(PanelInbound message) async {
    switch (message) {
      case PanelHello():
        await _welcome(message);
      case PanelChatsRequested():
        _sendChats();
      case PanelFocused(:final chatId):
        _followFocus(chatId);
      case PanelScrolled():
        // Straight through, with no throttling or accumulation of its own: the
        // panel already sends one report per ~8px or ~50ms, whichever comes
        // first, and doing it twice would add lag to the one message on this
        // link whose whole value is being immediate. Smoothing here would also
        // blunt the release speed, which is measured on the glass precisely
        // because that is the only place the hand's actual speed exists.
        _ref.read(panelScrollProvider.notifier).reported(message);
      case PanelStopRequested(:final chatId):
        _stopChat(chatId);
      case PanelTurnRequested(:final chatId, :final text):
        _startTurn(chatId, text);
      case PanelAnswered(:final chatId, :final id, :final optionId):
        _answerQuestion(chatId, id, optionId);
      case PanelVoiceBegin(:final chatId, :final command, :final lang):
        _beginVoice(chatId, command, lang);
      case PanelVoiceEnd():
        await _finishVoice();
      case PanelVoiceConfirm(:final routeId, :final chatId):
        _confirmVoice(routeId, chatId);
      case PanelFirmwareAccepted():
        _firmware.accepted();
      case PanelFirmwareProgress(:final written):
        _firmware.progress(written);
      case PanelFirmwareDone():
        // Remembered against the version the panel reported *before* this
        // update, so a device that reboots still calling itself that is not
        // offered the same image again.
        if (_mac.isNotEmpty) _flashed[_mac] = _firmwareVersion;
        _firmware.done();
      case PanelFirmwareFailed(:final message):
        _firmware.failed(message);
      case PanelPong():
        // Nothing to do here on purpose. The work a pong does happens one layer
        // down, where the bytes land: PanelPort times the silence and reopens a
        // handle that has gone stale. This case exists so the answer to our own
        // heartbeat is not logged as a message the build cannot read, four
        // hundred times an hour.
        break;
      case PanelUnknown(:final type):
        _log.warn('panel', 'Panel sent "$type", which this build cannot read');
      case PanelMalformed(:final reason):
        _log.warn('panel', 'Unreadable message from the panel: $reason');
    }
  }

  /// Answer the panel's introduction, and say which machine it is looking at —
  /// on this link simply the computer it is plugged into.
  Future<void> _welcome(PanelHello hello) async {
    // A `hello` is not proof of a new panel. The firmware keeps saying it on a
    // keepalive — every 15s once a session is up — because it has no port-open
    // event to wait on and the app may start at any moment. Measured on real
    // hardware 2026-08-17: the panel greeted a connected app four times a
    // minute, forever.
    //
    // So a repeat from the same board is answered but NOT re-attached. Attaching
    // clears what the mirrors believe this panel already knows, and doing that
    // on a timer would re-send the whole turn, question and tile state every 15
    // seconds — the one thing `PanelTurnMirror` exists to prevent, undone by the
    // handshake rather than by any change in state.
    final resumed = _greeted && _mac == hello.mac;
    _mac = hello.mac;
    _firmwareVersion = hello.firmware;
    _greeted = true;
    // Logged once per session, not per keepalive: a line every 15 seconds
    // buries everything else in the panel log, and the second one says nothing
    // the first didn't.
    if (!resumed) {
      _log.info(
        'panel',
        'Panel ${hello.mac} said hello '
            '(firmware ${hello.firmware}, protocol ${hello.protocol})',
      );
    }
    // Answered even when the versions disagree. The app carries the firmware
    // image and can reflash over this same cable, so a mismatch is a state to
    // act on — and the panel only learns which version to reflash to from the
    // `welcome` it gets back.
    if (!hello.isCompatible) {
      _log.warn(
        'panel',
        'Panel speaks protocol ${hello.protocol} and this build speaks '
            '$kPanelProtocolVersion — it needs reflashing',
      );
    }
    _ref
        .read(panelLinkProvider)
        .send(
          PanelOutbound.welcome(
            appVersion: await _appVersion(),
            machineId: _ref.read(nodeNameProvider),
            machineName: _machineName(),
            // The same function the mic button and every panel capture go
            // through, so the Settings page cannot report one language while the
            // transcriber is given another.
            voiceLang: preferredSttLang(),
          ),
        );
    // Everything below re-establishes a panel that knows nothing, so it runs
    // only for one that actually does — a fresh board, or the same board back
    // from a reboot with its screen empty. A keepalive greeting from a panel
    // already holding this state gets the `welcome` above and nothing more.
    if (resumed) {
      await _offerFirmware(hello);
      return;
    }
    // A panel plugged in mid-turn — or one that has just rebooted after a flash
    // — knows nothing about work already running. Told now, its tile shows the
    // turn it walked in on instead of waiting for the next step to arrive.
    _push(
      _turns.onAttach(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        runs: _ref.read(agentRunsProvider),
      ),
    );
    _closeEndedTurns();
    // Including a question it is standing in front of: an agent waiting on a
    // yes does not ask twice, so a panel that woke up during one would show an
    // idle tile over a turn that is stopped dead.
    _push(
      _questions.onAttach(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        permissions: _ref.read(agentPermissionsProvider),
      ),
    );
    // The tiles are sent when it asks (`projects.list`, which it does on
    // waking); what is forgotten here is what the *app* thinks it has already
    // told this panel, which belonged to the one that was plugged in before.
    _tiles.forget();
    await _offerFirmware(hello);
  }

  /// Tell the panel whatever has changed about the turns in flight.
  ///
  /// Called on every chat-state and run-feed change, which is often — a turn
  /// publishes a phase per streamed token. [PanelTurnMirror] is what makes that
  /// affordable: it says nothing when nothing the panel can draw has moved.
  void mirrorTurns() {
    _push(
      _turns.onChange(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        runs: _ref.read(agentRunsProvider),
      ),
    );
    // AFTER the push, never before: a turn that worked has just gone out as
    // `turn.summarizing`, and this is what owes it the `turn.done` that ends it.
    // Run first, the end of the turn reached the panel ahead of the news that it
    // was still being read.
    _closeEndedTurns();
    final deferred = _deferredOffer;
    // A panel plugged in during a turn is not offered an update then. This is
    // the moment that changes: the machine has just gone idle, and the panel
    // will not say `hello` again until it is unplugged.
    if (deferred == null || _anyTurnRunning()) return;
    _deferredOffer = null;
    unawaited(_offerFirmware(deferred));
  }

  /// Tell the panel whatever has changed about the questions an agent is
  /// waiting on.
  void mirrorQuestions() {
    _push(
      _questions.onChange(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        permissions: _ref.read(agentPermissionsProvider),
      ),
    );
  }

  /// Rebuild the tiles soon, and once, however many changes arrive first.
  ///
  /// [kPanelChatsCoalesce] after the first change in a burst — long enough that
  /// a streaming reply does not rebuild the list per token, short enough that
  /// picking a model in the window reads as instant on the glass.
  void scheduleChatsMirror() {
    if (_chatsPending != null) return;
    _chatsPending = Timer(kPanelChatsCoalesce, () {
      _chatsPending = null;
      mirrorChats();
    });
  }

  Timer? _chatsPending;

  /// The tiles that fit one frame, and a line in the log naming what did not.
  ///
  /// Said out loud rather than trimmed quietly: a panel showing eleven of
  /// thirteen chats looks exactly like a panel showing all of them, so the two
  /// are only ever told apart here.
  List<PanelChat> _tilesThatFit(List<PanelChat> tiles) {
    final kept = panelTilesThatFit(tiles);
    if (kept.length != tiles.length) {
      _log.warn(
        'panel',
        'Tiles trimmed to fit one frame: sent ${kept.length} of '
            '${tiles.length}',
      );
    }
    return kept;
  }

  /// Tell the panel whatever has changed about the tiles themselves.
  void mirrorChats() {
    final tiles = _tilesThatFit(
      panelChatsFor(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        history: _ref.read(panelRecapsProvider),
        defaultAgent: _ref.read(chatPrefsProvider).chatAgent,
      ),
    );
    final messages = _tiles.onChange(tiles);
    if (messages.isNotEmpty) {
      // Evidence, deliberately. A tile that does not change on the glass leaves
      // nothing in this log either, so "did the app even send it?" has no
      // answer and the hunt starts with a guess. Only fires when something
      // actually goes out, which is rare — the mirror drops everything else.
      _log.info(
        'panel',
        'Tiles changed: ${messages.length} message(s); '
            '${[for (final t in tiles) '${t.name}=${t.model ?? '-'}'].join(', ')}',
      );
    }
    _push(messages);
  }

  /// The user answered a question on the panel.
  ///
  /// Routed through [AgentPermissionController.answer] rather than straight
  /// back to the agent, because answering is more than a reply: it stops the
  /// countdown, takes the card off the window, and records an approved edit so
  /// it can be undone. A panel answer that skipped it would leave the desktop
  /// showing a question nobody is waiting on.
  void _answerQuestion(String chatId, String id, String optionId) {
    // Settled while the answer was in flight — the two surfaces race by design
    // and the loser is dropped without a word.
    if (!_questions.isAsking(chatId, id)) return;
    final request = _ref.read(agentPermissionsProvider)[chatId];
    if (request == null) return;
    final choice = panelChoiceForAnswer(optionId, request);
    if (choice == null) {
      _log.warn(
        'panel',
        'Panel answered "$optionId", which is not one of the options that '
            'question was sent with — ignored',
      );
      return;
    }
    _log.info('panel', 'Panel answered a permission in $chatId: $optionId');
    _ref.read(agentPermissionsProvider.notifier).answer(chatId, choice);
  }

  /// A turn ended: write the long form of its recap and send it after the fact.
  ///
  /// Never awaited by the caller. `turn.done` has already gone out, and this
  /// takes as long as a model takes — holding the two together would leave a
  /// tile spinning on work that finished seconds ago.
  /// Remember how a turn came out, for the voice router to read later.
  ///
  /// Every turn, not only the ones a model summarised: the cheap headline is
  /// weaker signal but it is signal, and a chat with no history at all is one
  /// the router can only match by its title.
  void _rememberTurn(
    String chatId, {
    required String recap,
    String summary = '',
  }) => _ref
      .read(panelRecapsProvider.notifier)
      .record(chatId, recap: recap, summary: summary);

  /// Close out every turn that settled on the last pass.
  ///
  /// One `turn.done` each, without exception. The mirror has already told the
  /// panel `turn.summarizing` for each of them, which leaves its tile working —
  /// so a turn dropped here is a tile that works forever on finished work.
  void _closeEndedTurns() {
    for (final ended in _turns.drainEnded()) {
      _summarize(ended.chatId, ended.chat);
    }
  }

  /// A turn ended well; the panel has been told `turn.summarizing` and is owed a
  /// `turn.done`.
  ///
  /// No panel has greeted us, or the chat is gone: nothing is watching, so close
  /// it out at once rather than paying for a model. The send is harmless either
  /// way — a panel that never heard `turn.summarizing` reads `turn.done` for a
  /// chat it thinks is idle as "that chat is idle now", which the protocol
  /// already requires it to tolerate.
  void _summarize(String chatId, Conversation? chat) {
    if (chat == null || !_greeted) {
      final recap = panelRecapOf(chat);
      _rememberTurn(chatId, recap: recap);
      _ref
          .read(panelLinkProvider)
          .send(PanelOutbound.turnDone(chatId: chatId, recap: recap));
      return;
    }
    unawaited(_writeSummary(chatId, chat));
  }

  /// Write the headline, then close the turn out on the panel.
  ///
  /// **This must always end in a `turn.done`.** `_settle` has already told the
  /// panel `turn.summarizing`, which leaves its tile in the working state — so
  /// every path out of here, including every failure, owes it a terminal
  /// message. Drop one and the tile works forever on a turn that ended.
  Future<void> _writeSummary(String chatId, Conversation chat) async {
    PanelTurnSummary? written;
    String? failure;
    final clock = Stopwatch()..start();
    // Hold the tile awake for as long as this takes. The device frees a busy tile
    // after 25s of silence and a real model can spend longer than that on one
    // prompt, so the window is kept open by repeating rather than by hoping the
    // write is quick. This is the beat the reference sends too, and skipping it —
    // bounding the write under 25s instead — is what made the first deadline too
    // tight to ever be met.
    final beat = Timer.periodic(
      kPanelSummarizingBeat,
      (_) => _ref
          .read(panelLinkProvider)
          .send(PanelOutbound.turnSummarizing(chatId)),
    );
    _summarizing.add(beat);
    try {
      (written, failure) = await _ref
          .read(panelSummaryWriterProvider)
          .write(chat, budget: kPanelSummaryDeadline)
          .timeout(kPanelSummaryDeadline);
    } on TimeoutException {
      failure =
          'the model took longer than ${kPanelSummaryDeadline.inSeconds}s';
    } finally {
      beat.cancel();
      _summarizing.remove(beat);
    }
    // A model takes seconds and the app can be quit inside one of them. Nothing
    // below this line may touch the container once it has gone.
    if (!_ref.mounted) return;
    // Logged every time, pass or fail: this number is the only evidence for what
    // the deadline should be, and the first guess at it was wrong by a factor of
    // three.
    _log.info(
      'panel',
      'The headline for $chatId took ${clock.elapsed.inSeconds}s',
    );

    final link = _ref.read(panelLinkProvider);
    if (written == null) {
      // The cheap recap — the agent's own last sentence, cut to a line — is what
      // there is to show when no model would read the turn. Logged with the real
      // reason, because the panel is given a sentence about the WORK and never
      // one apologising for a model: that would be four lines of a 466px screen
      // spent saying nothing about what happened (§5).
      _log.warn('panel', 'No headline for the turn in $chatId: $failure');
      link.send(
        PanelOutbound.turnDone(chatId: chatId, recap: panelRecapOf(chat)),
      );
      return;
    }
    _rememberTurn(chatId, recap: written.recap, summary: written.summary);
    link.send(PanelOutbound.turnDone(chatId: chatId, recap: written.recap));
    // Second, and only when there is one. The headline ends the turn; the body
    // is what the reader screen shows behind it.
    if (written.summary.isNotEmpty) {
      link.send(PanelOutbound.summary(chatId: chatId, text: written.summary));
    }
  }

  void _push(List<String> messages) {
    if (messages.isEmpty) return;
    final link = _ref.read(panelLinkProvider);
    for (final message in messages) {
      link.send(message);
    }
  }

  /// Send the tiles: every chat, in the order the app's own sidebar draws them,
  /// so the panel and the rail never disagree about what comes first.
  void _sendChats() {
    final tiles = _tilesThatFit(
      panelChatsFor(
        projects: _ref.read(sortedProjectsProvider),
        chats: _ref.read(chatSessionsProvider),
        history: _ref.read(panelRecapsProvider),
        defaultAgent: _ref.read(chatPrefsProvider).chatAgent,
      ),
    );
    _ref.read(panelLinkProvider).send(_tiles.all(tiles));
  }

  /// Interrupt the turn running in [chatId].
  ///
  /// One chat, because one chat is what a tile is now. It used to stop every
  /// conversation in a project, which was right while a tile spoke for all of
  /// them and is wrong now: the neighbouring chat's turn is its own tile, and
  /// stopping work the user did not point at is not what Stop means.
  ///
  /// [ChatSessionsController.stopChat] is a no-op on a chat with nothing in
  /// flight, so this costs nothing when the tile was already idle.
  void _stopChat(String chatId) =>
      _ref.read(chatSessionsProvider.notifier).stopChat(chatId);

  /// Start a turn the user asked for on the panel.
  ///
  /// It goes into the chat the tile IS — no picking, no "most recently used",
  /// no new conversation. That guesswork existed while a tile stood for a whole
  /// project; the panel now names the conversation, so the panel and the window
  /// are looking at the same transcript by construction.
  ///
  /// Every way this can fail is answered in words. Silence would leave the tile
  /// spinning on work that is never coming, and the panel has no other way to
  /// find out: it runs no model, reads no disk and cannot see the window.
  void _startTurn(String chatId, String text) {
    final asked = text.trim();
    if (asked.isEmpty) {
      _refuseTurn(chatId, 'That arrived with no words in it. Say it again?');
      return;
    }

    final chats = _ref.read(chatSessionsProvider);
    final chat = panelChatById(chats, chatId);
    if (chat == null || chat.isArchived) {
      _refuseTurn(chatId, 'This computer no longer has that chat.');
      return;
    }
    final project = _ref.read(projectByIdProvider(chat.projectId));
    if (project == null) {
      _refuseTurn(chatId, 'This computer no longer has that project.');
      return;
    }
    // THIS chat, not its project's. Two chats in one folder answering at once
    // is ordinary since `bf462afc`, and refusing the second because the first
    // is busy would be the panel enforcing a rule the app dropped.
    if (panelTurnInFlight(chats, chatId)) {
      _refuseTurn(
        chatId,
        'This chat is already working. Press stop first, or wait for it.',
      );
      return;
    }

    // Read before the model: with no grid there is nothing to serve a model
    // either, and "pick a grid" is the step that unblocks both.
    final network = _ref.read(selectedNetworkProvider);
    if (network == null) {
      _refuseTurn(
        chatId,
        'No grid is open on this computer. Open Grid and pick one.',
      );
      return;
    }

    final model = _modelFor(project, chat);
    if (model.isEmpty) {
      _refuseTurn(
        chatId,
        'No model is available on this grid. Start one in Grid, then try again.',
      );
      return;
    }

    _log.info('panel', 'Panel started a turn in ${chat.title}');
    unawaited(_dispatchTurn(chat, network, model, asked));
  }

  /// Hand the turn to [ChatSessionsController] and report a start that never
  /// got off the ground.
  ///
  /// Not awaited by the caller: `send` completes when the *turn* does, which is
  /// minutes for an agent, and the panel's next message (Stop, most of all)
  /// must not queue behind it. Everything after this point reaches the panel
  /// through [mirrorTurns] instead.
  Future<void> _dispatchTurn(
    Conversation chat,
    NetworkCredential network,
    String model,
    String text,
  ) async {
    try {
      // Opened BEFORE the send, not after. `send(into:)` deliberately leaves
      // the window where it is — that is right for a queued follow-up — so
      // without this the reply streams into a chat nobody is looking at.
      _showInWindow(chat.projectId, chat.id);
      final sessions = _ref.read(chatSessionsProvider.notifier);
      await sessions.send(
        network: network,
        model: model,
        message: text,
        into: chat.id,
      );
    } on Object catch (e) {
      _log.warn('panel', 'Panel turn in ${chat.id} could not start: $e');
      _refuseTurn(chat.id, "That couldn't be started here. Open Grid to see.");
    }
  }

  /// The window switched chats — move the carousel to it.
  ///
  /// The mirror of [_followFocus], and the same rule decides both: whichever
  /// screen the person touched is the one that says what both are looking at.
  ///
  /// **Dedup is what keeps the two ends from chasing each other.** A swipe
  /// makes the device send `focus`, which moves the window, which would send
  /// `focus` straight back. Remembering the last id sent breaks the loop on the
  /// first lap — and the device does the same on its side, so neither depends
  /// on the other being careful.
  ///
  /// A blank composer (`activeId == null`) says nothing: the user is starting a
  /// chat that does not exist yet, and there is no tile to move to.
  void followWindow(String? chatId) {
    if (chatId == null || chatId == _focus) return;
    if (!_greeted) return;
    _focus = chatId;
    _ref.read(panelLinkProvider).send(PanelOutbound.focus(chatId));
  }

  /// The chat the two screens last agreed on, from either direction.
  String _focus = '';

  /// Follow a swipe: show the chat the carousel settled on.
  ///
  /// The same three moves a turn started from the panel makes, and for the same
  /// reason — the panel and the window are one desk. The difference is that
  /// nothing is dispatched here: this is somebody LOOKING at a tile, so a chat
  /// the app no longer has is ignored in silence rather than answered. The
  /// panel is not waiting on a reply and has nothing to correct.
  void _followFocus(String chatId) {
    final chat = panelChatById(_ref.read(chatSessionsProvider), chatId);
    if (chat == null || chat.isArchived) return;
    // Recorded BEFORE the window moves, so the `activeId` listener that fires
    // next sees its own echo and says nothing back.
    _focus = chatId;
    _showInWindow(chat.projectId, chat.id);
  }

  /// Point the window at the turn the panel just started.
  ///
  /// The user asked for this — from the other side of the desk, but they asked
  /// — and a turn they cannot find is a turn they will start again. The panel
  /// says what happened in fifteen words; the window is where the actual work
  /// is legible, and on a desk with a panel on it the window is very often
  /// showing some other conversation entirely.
  ///
  /// All three, because any one alone leaves the window half-moved: the chat is
  /// what the reply streams into, the rail is what the Projects screen dresses
  /// itself for, and the section is which of those is on screen at all —
  /// [ShellSectionController.select] also brings the window back from Code,
  /// where "go to Chat" would otherwise change something nobody can see.
  ///
  /// **Not** a window raise. The person is looking at the panel, quite possibly
  /// with another app in front; stealing the screen because they spoke would be
  /// a worse trade than making them click Grid when they turn back to it.
  void _showInWindow(String? projectId, String chatId) {
    _ref.read(chatSessionsProvider.notifier).select(chatId);
    if (projectId != null) {
      _ref.read(selectedProjectIdProvider.notifier).select(projectId);
    }
    _ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  /// What to answer a panel turn with: the project's own model, else the one
  /// that chat last ran on, else the app's standing choice, else whatever this
  /// grid is serving.
  ///
  /// The remembered choices are taken as they stand rather than checked against
  /// the grid's list. That list is fetched, and it is empty for the first
  /// moment of a session and on every refresh — checking against it would turn
  /// a panel turn into "no model available" over a grid serving a dozen.
  String _modelFor(Project project, Conversation? target) {
    final remembered =
        project.model ?? target?.model ?? _ref.read(chatPrefsProvider).model;
    if (remembered != null && remembered.trim().isNotEmpty) {
      return remembered.trim();
    }
    final options = _ref.read(playgroundModelsProvider);
    return options.isEmpty ? '' : options.first.id;
  }

  /// Tell the panel a turn it asked for is not happening, and why.
  void _refuseTurn(String chatId, String message) {
    _log.warn('panel', 'Panel turn in $chatId refused: $message');
    _ref
        .read(panelLinkProvider)
        .send(PanelOutbound.turnError(chatId: chatId, message: message));
  }

  /// Start collecting what the user is saying.
  ///
  /// A capture already open is dropped rather than continued: a second
  /// `voice.begin` means the first one's `voice.end` never arrived, and the
  /// sentence being spoken now is the one somebody is waiting on.
  void _beginVoice(String? chatId, PanelVoiceCommand command, String? lang) {
    _voiceOpen?.cancel();
    _voice = PanelVoiceCapture(chatId: chatId, command: command, lang: lang);
    _voiceOpen = Timer(kPanelVoiceOpenLimit, () => unawaited(_finishVoice()));
  }

  /// One PCM chunk. Dropped when nothing is being captured — a frame that
  /// arrives just after a capture was closed is late, not a new sentence.
  void _onAudio(List<int> chunk) {
    final capture = _voice;
    if (capture == null) return;
    capture.add(chunk);
    // Finished here rather than waited for. The panel stops its own microphone
    // at the same ten minutes, so a capture that reaches the ceiling here is one
    // whose `voice.end` is not coming.
    if (capture.isFull) unawaited(_finishVoice());
  }

  /// Turn the captured audio into a turn, or say why it could not be.
  ///
  /// Every exit answers the panel. It is showing a screen that says it is
  /// listening, and it has no other way to learn otherwise: it runs no model,
  /// reads no disk and cannot see this window.
  Future<void> _finishVoice() async {
    final capture = _voice;
    _voice = null;
    _voiceOpen?.cancel();
    _voiceOpen = null;
    // A `voice.end` with no capture behind it promised the panel nothing —
    // answering an error would put a failure on screen for a sentence that was
    // already delivered.
    if (capture == null) return;
    if (capture.length == 0) {
      _voiceError(
        'No sound arrived from the panel. Check its microphone and try again.',
      );
      return;
    }
    if (capture.truncated) {
      _log.warn(
        'panel',
        'A voice capture filled its $kPanelVoiceMaxBytes-byte ceiling; '
            'everything after the first ten minutes was dropped',
      );
    }
    final client = _ref.read(sttClientProvider);
    if (client == null) {
      _voiceError(kSttUnavailableMessage);
      return;
    }
    switch (await _transcribe(client, capture)) {
      case SttFailure(:final message):
        _voiceError(message);
      case SttSuccess(:final text):
        // Nothing came back. On its own that is two failures wearing one
        // sentence — a microphone that sent silence, and a transcriber that
        // could not place real words — so the capture is described here, where
        // the bytes are still in hand and the answer is already known to be
        // empty. `peak` separates them: near zero is the device's problem, and
        // 32767 is a signal so hot it has been clipped flat.
        //
        // Only on this branch. A line per capture would say the same thing
        // about every working turn, and the one time it matters is the one time
        // nobody can see what happened. It has earned its place twice:
        // 8 kHz audio labelled 16 kHz, and a railed mic.
        if (text.trim().isEmpty) {
          _log.warn(
            'panel',
            'Nothing was transcribed from ${capture.describe()}',
          );
        }
        // The modifier goes on here, not on the panel and not in the router:
        // this is the last point where the words are still just words, and the
        // next thing that happens to them is being sent as a message.
        _routeTranscript(
          capture.chatId,
          '${capture.command.prefix}${text.trim()}',
        );
    }
  }

  /// Write the clip and hand it to `grid stt transcribe`.
  ///
  /// A file on disk because that is the interface [SttClient] already has, and
  /// the reason it has it is worth keeping: the CLI holds the session token, so
  /// the app never carries a cloud credential and neither does the panel.
  Future<SttResult> _transcribe(
    SttClient client,
    PanelVoiceCapture capture,
  ) async {
    Directory? dir;
    try {
      dir = await Directory.systemTemp.createTemp('grid_panel_voice_');
      final clip = File('${dir.path}/clip.wav');
      await clip.writeAsBytes(capture.toWav(), flush: true);
      return await client.transcribe(
        audioPath: clip.path,
        // The DEVICE's choice wins. Its Settings page owns this once someone has
        // tapped the row, and the app's own reading of the machine locale is only
        // the proposal it started from (`welcome.voiceLang`) — so falling back to
        // it here is for a firmware old enough not to send one, not for a
        // disagreement. Asking for the wrong language does not degrade a
        // transcript, it empties it.
        lang: capture.lang?.trim().isNotEmpty == true
            ? capture.lang!.trim()
            : preferredSttLang(),
      );
    } on Object catch (e) {
      _log.warn('panel', 'A panel voice clip could not be transcribed: $e');
      return const SttFailure(
        "That couldn't be sent for transcription. Try again.",
      );
    } finally {
      await _deleteClip(dir);
    }
  }

  /// Best-effort: a leftover temp file costs nothing worth failing a turn over.
  Future<void> _deleteClip(Directory? dir) async {
    if (dir == null) return;
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      return;
    }
  }

  /// Send the transcript where it belongs — or ask, when the app is guessing.
  void _routeTranscript(String? spokenIn, String text) {
    if (text.isEmpty) {
      _voiceError("I couldn't make out any words. Try again, a little closer.");
      return;
    }
    final route = panelVoiceRouteFor(
      spokenIn: spokenIn,
      projects: _ref.read(sortedProjectsProvider),
      chats: _ref.read(chatSessionsProvider),
    );
    final routeId = 'r${++_routes}';
    switch (route) {
      case PanelVoiceRouted(:final chatId):
        // The panel named it. Nothing to decide, and nothing a model could add.
        _sendTranscript(routeId, chatId, text, needsConfirm: false);
        _startTurn(chatId, text);
      case PanelVoiceGuessed(:final chatId):
        // Spoken from the Overview, where no project is named. `projectId` here
        // is the app's own guess — the most recently used one — and it stands as
        // the answer only if the router cannot do better.
        unawaited(_routeByModel(routeId, chatId, text));
      case PanelVoiceUnroutable(:final message):
        _voiceError(message);
    }
  }

  /// Ask a model which conversation a sentence spoken from the Overview belongs
  /// to.
  ///
  /// The titles alone are a strong signal — a chat is named after what it is
  /// about — but they tie often enough ("Fix login" and "Fix login again") that
  /// what each one has recently *done* is what breaks it. That history is the
  /// whole reason [panelRecapsProvider] exists.
  ///
  /// [fallback] is the app's own guess, and it is what a failure resolves to: the
  /// router being unreachable must not lose a sentence someone already said out
  /// loud.
  Future<void> _routeByModel(
    String routeId,
    String fallback,
    String text,
  ) async {
    final recaps = _ref.read(panelRecapsProvider.notifier);
    // In the panel's own tile order, so the router's own fallback — the first
    // candidate — is the same chat the app would have guessed without it.
    //
    // CUT to the front of that list. One tile per chat means this can be a
    // hundred conversations, and a hundred-line prompt is both a bill and a
    // worse decision: the model is being asked to hold every chat on the
    // machine in mind to place one sentence. The front of the list is where a
    // spoken sentence belongs almost every time — it is ordered by what was
    // talked in most recently.
    final tiles = panelChatsFor(
      projects: _ref.read(sortedProjectsProvider),
      chats: _ref.read(chatSessionsProvider),
      limit: kPanelRouteCandidates,
    );
    final candidates = [
      for (final tile in tiles)
        PanelRouteCandidate(
          id: tile.id,
          name: tile.project.isEmpty
              ? tile.name
              : '${tile.name} — ${tile.project}',
          recent: recaps.recentFor(tile.id),
        ),
    ];

    PanelRouteDecision? decision;
    var timedOut = false;
    // Timed, and the elapsed time is in the log line either way. "The router did
    // not answer" was the same sentence whether the model was unreachable, said
    // something unusable, or answered a second late — and on 2026-08-17 it was
    // the third one, which cost a debugging session to tell apart from the first.
    final clock = Stopwatch()..start();
    try {
      decision = await _ref
          .read(panelVoiceRouterProvider)
          .route(text, candidates)
          .timeout(kPanelRouteDeadline);
    } on TimeoutException {
      timedOut = true;
      decision = null;
    }
    clock.stop();
    if (!_ref.mounted) return;

    final took = '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(0)}s';
    final chatId = decision?.chatId ?? fallback;
    if (decision == null) {
      _log.warn(
        'panel',
        timedOut
            ? 'The router was still thinking after $took, so the sentence goes '
                  'to $chatId — where this computer was last spoken to. The '
                  'answer may yet arrive and will be ignored.'
            : 'The router had nothing to say after $took (no model reachable, or '
                  'an unusable answer); sending the sentence to $chatId, '
                  'which is where this computer was last spoken to',
      );
    } else {
      _log.info(
        'panel',
        'The router chose $chatId at ${decision.confidence.toStringAsFixed(2)}'
            ' in $took'
            '${decision.reason.isEmpty ? '' : ': ${decision.reason}'}',
      );
    }

    // Confident enough to act on, or confident enough only to offer. A pick in
    // the router's lower bands dispatching itself into a real repository is the
    // failure the confirm step exists to prevent — and the sentence is already
    // said, so the cost of asking is one tap.
    if (decision != null && decision.isConfident) {
      _sendTranscript(routeId, chatId, text, needsConfirm: false);
      _startTurn(chatId, text);
      return;
    }
    _remember(routeId, chatId, text);
    _sendTranscript(routeId, chatId, text, needsConfirm: true);
  }

  void _sendTranscript(
    String routeId,
    String chatId,
    String text, {
    required bool needsConfirm,
  }) {
    // The words themselves stay out of the log: they are the user's, and the
    // interesting fact here is where they were sent and whether the app was
    // sure. What was said is in the chat it landed in.
    _log.info(
      'panel',
      needsConfirm
          ? 'Panel heard ${text.length} characters and guesses they belong to '
                '$chatId — waiting for the panel to confirm'
          : 'Panel heard ${text.length} characters for $chatId',
    );
    _ref
        .read(panelLinkProvider)
        .send(
          PanelOutbound.voiceTranscript(
            routeId: routeId,
            text: text,
            chatId: chatId,
            needsConfirm: needsConfirm,
          ),
        );
  }

  /// Hold a guessed transcript until the panel says where it goes.
  ///
  /// Bounded, oldest first: an unconfirmed transcript is one the user walked
  /// away from, and the panel asks about one at a time — so a handful covers
  /// every real case and nothing can grow this without limit.
  void _remember(String routeId, String chatId, String text) {
    _guessed[routeId] = (chatId: chatId, text: text);
    while (_guessed.length > kPanelVoicePendingLimit) {
      _guessed.remove(_guessed.keys.first);
    }
  }

  /// The user picked a chat for a transcript the app had guessed at.
  ///
  /// [chatId] wins over the guess: the panel offers the other tiles, and the
  /// whole point of asking is that the answer can differ.
  void _confirmVoice(String routeId, String chatId) {
    final pending = _guessed.remove(routeId);
    if (pending == null) {
      _voiceError('That one is no longer waiting to be sent. Say it again?');
      return;
    }
    final target = chatId.trim();
    _startTurn(target.isEmpty ? pending.chatId : target, pending.text);
  }

  /// Tell the panel voice went wrong, in words a person can act on.
  void _voiceError(String message) {
    _log.warn('panel', 'Panel voice failed: $message');
    _ref.read(panelLinkProvider).send(PanelOutbound.voiceError(message));
  }

  /// The firmware handover for this session.
  ///
  /// Built on first use because it holds the link, and [panelLinkProvider] is a
  /// plain provider whose object lives as long as this controller does.
  PanelFirmwareUpdater get _firmware => _updater ??= PanelFirmwareUpdater(
    link: _ref.read(panelLinkProvider),
    log: _log,
    onGaveUp: (version) {
      if (_mac.isNotEmpty) _refused[_mac] = version;
    },
  );

  /// Offer the firmware this build carries, when the panel is running another
  /// one and this is a safe moment to say so.
  ///
  /// The app ships the image its own build was compiled against, so "the panel
  /// is running something else" always means one half is behind the other.
  Future<void> _offerFirmware(PanelHello hello) async {
    final image = await _ref.read(panelFirmwareProvider.future);
    if (image == null || image.version == hello.firmware) return;
    if (_firmware.busy) return;
    if (_anyTurnRunning()) {
      _log.info(
        'panel',
        'The panel runs firmware ${hello.firmware} and this build carries '
            '${image.version}, but a turn is running — not offering yet',
      );
      _deferredOffer = hello;
      return;
    }
    if (_refused[hello.mac] == image.version) {
      // Once per session, not once per hello: the log line that matters is the
      // one the failure itself wrote, and repeating it every fifteen seconds
      // would bury it.
      return;
    }
    if (_flashed[hello.mac] == hello.firmware) {
      // Loud, because there is only one cause and it is not fixable from here:
      // the device reports a version string that is not the one inside the
      // image it was just given, so every comparison will mismatch forever.
      _log.warn(
        'panel',
        'The panel rebooted still reporting firmware ${hello.firmware} after '
            'being written ${image.version} — its `hello.fw` and the image it '
            'runs disagree, so no further update is offered this session',
      );
      return;
    }
    _firmware.offer(image);
  }

  /// Whether any project on this machine has a turn in flight.
  ///
  /// The gate on a firmware offer: accepting one reboots the panel into a
  /// flash, and a tile going dark in the middle of work somebody is watching is
  /// the one moment an update must never start.
  bool _anyTurnRunning() {
    final chats = _ref.read(chatSessionsProvider);
    return chats.live.any((c) => panelTurnInFlight(chats, c.id));
  }

  /// This app's version, or empty when the platform channel does not answer.
  ///
  /// Only ever tells the panel which app it is talking to. A version that could
  /// not be read must not be why the handshake fails.
  Future<String> _appVersion() async {
    try {
      return await _ref.read(appVersionProvider.future);
    } on Object {
      return '';
    }
  }

  /// What this computer calls itself, for the panel's header.
  String _machineName() {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? 'This computer' : name;
  }

  AppLog get _log => _ref.read(appLogProvider);
}

/// How many tiles the panel is sent at most.
///
/// The firmware allocates its tile array up front — `MAX_TILES` in
/// `panel_client.h`, ~28 KB of PSRAM — so a longer list is not a slower panel,
/// it is a panel that drops the tail without knowing it did. Matched here so
/// the cut happens on the side that can say what was cut.
const int kPanelMaxTiles = 100;

/// The panel's view of the app's chats — one tile each, **in the order the
/// sidebar draws them**.
///
/// Project by project in [projects] order, and inside each the order
/// `liveConversations` already fixed (pinned first, then most recently talked
/// in). Reusing that rather than sorting again is the point: the rail, ⌘K and
/// the panel would otherwise be three answers to "which chats matter, and in
/// what order".
///
/// **Chats outside every project are left out.** The panel has never shown them
/// and nothing here changes that — a tile's subtitle is its project, and a
/// tile with no subtitle is the one row on the carousel that cannot say where
/// its work would land.
///
/// Pure, and the one place the app's state becomes the panel's: a tile is
/// derived, never stored, so nothing can go stale between the two screens.
List<PanelChat> panelChatsFor({
  required List<Project> projects,
  required ChatSessionsState chats,
  Map<String, List<PanelTurnRecord>> history = const {},

  /// The app's standing agent choice, for a project that has made none.
  String? defaultAgent,
  int limit = kPanelMaxTiles,
}) {
  final tiles = <PanelChat>[];
  for (final project in projects) {
    for (final conversation in chats.live) {
      if (conversation.projectId != project.id) continue;
      if (tiles.length >= limit) return tiles;
      tiles.add(
        panelChatFor(
          conversation,
          project,
          chats,
          history[conversation.id]?.firstOrNull,
          defaultAgent,
        ),
      );
    }
  }
  return tiles;
}

/// One chat as a tile: its title, the project it sits in, which assistant
/// answered it, whether it is working right now, and one line of what was last
/// said there.
///
/// Thin on purpose — the panel is 466px across. The transcript, the
/// instructions and the workspace path stay in the app.
PanelChat panelChatFor(
  Conversation conversation,
  Project project,
  ChatSessionsState chats, [
  PanelTurnRecord? last,
  String? defaultAgent,
]) => PanelChat(
  id: conversation.id,
  // Clipped, unlike everywhere else a title is drawn. The panel is 466px of
  // glass on the other end of a cable with an 8192-byte frame budget, and
  // titles stopped being clipped in the store on 2026-08-20 so a rename could
  // offer the whole name back. Thirty-odd tiles' worth of full sentences went
  // straight past the budget the same day — `over the 8192-byte frame limit:
  // 11724`, thrown out of the mirror where nothing was catching it.
  name: clipChatTitle(conversation.title),
  project: clipChatTitle(project.name),
  // WHO WILL ANSWER THE NEXT TURN, which is not always who answered the last
  // one. The pick the user made — on the project, or the app's standing choice
  // — wins, because a tile is a thing you speak into from the panel and the
  // mark on it is a promise about what happens when you do.
  //
  // I had this the other way round until 2026-08-19: the tile read the agent
  // STAMPED on the last reply, so a chat with Hermes history went on showing
  // Hermes after the user switched it to Claude, and would have until Claude
  // answered once. Reported from the desk in exactly those words.
  //
  // The stamp is still the fallback, and it earns its place under **Auto**:
  // there the grid picks per turn, so there is no choice to show and the last
  // agent to speak is the most informative thing left.
  agent: _agentChoiceOf(project, defaultAgent) ?? _agentOf(conversation),
  model: conversation.model.isNotEmpty ? conversation.model : project.model,
  // One chat, one turn: no rule is needed for which of a project's chats the
  // tile speaks for, because there is no longer a tile that speaks for more
  // than one. That rule is what dropped a live turn when two chats in a folder
  // ran at once (see [panelRunningChatsOf]).
  busy: panelTurnInFlight(chats, conversation.id),
  // The REMEMBERED headline, when there is one — the ≤15-word line a model
  // wrote when that turn ended, which is what the tile is meant to draw.
  //
  // The last thing said in the chat, cut to one line, is only the fallback:
  // that is what there is before any turn has been summarised, and on a cold
  // start it used to be all the panel ever got. A first line of prose and a
  // headline are not the same thing, and it showed — the tile and the reader
  // were handed one string and drew it twice.
  recap: last?.recap.isNotEmpty == true
      ? last!.recap
      : panelRecapOf(conversation),
  // The long form, so a panel plugged in cold has something behind the
  // headline. Absent until a model has written one, and then the reader says
  // there is nothing more rather than repeating the headline.
  summary: last?.summary ?? '',
  // Read off the same chat as the line above, so a recap and the colour behind
  // it always describe one turn.
  recapKind: panelRecapKindOf(
    failure: chats.errorFor(conversation.id),
    conversation: conversation,
  ),
);

/// The agent the user picked for this chat, or null when they picked Auto or
/// picked nothing.
///
/// Auto is a real choice and still returns null here: it means "the grid
/// decides per turn", which is not an agent and has no mark to draw.
String? _agentChoiceOf(Project project, String? defaultAgent) {
  final chosen = project.agent ?? defaultAgent;
  if (chosen == null || chosen.isEmpty || isAutoAgentId(chosen)) return null;
  return chosen;
}

/// The agent id stamped on this chat's most recent reply, or null when nothing
/// has answered in it yet.
///
/// Read off the transcript rather than from a field, the same way
/// `ChatSessionsController` decides who continues a chat: the stamp is
/// persisted with the reply, so it survives a restart and it describes what
/// actually happened rather than what was configured.
String? _agentOf(Conversation conversation) {
  for (final message in conversation.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    final agent = message.agent;
    if (agent != null && agent.isNotEmpty) return agent;
  }
  return null;
}
