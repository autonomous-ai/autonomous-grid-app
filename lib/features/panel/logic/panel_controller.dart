import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/panel/panel_link.dart';
import '../../../infrastructure/panel/panel_link_provider.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/app_info.dart';
import '../../agents/logic/agent_providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
import '../../playground/logic/playground_models.dart';
import '../../projects/logic/project.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import 'panel_turn_mirror.dart';

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
  ref.listen(chatSessionsProvider, (_, _) => controller.mirrorTurns());
  ref.listen(agentRunsProvider, (_, _) => controller.mirrorTurns());
  ref.onDispose(controller.stop);
  return controller;
});

/// Answers the panel over [panelLinkProvider].
class PanelController {
  PanelController(this._ref);

  final Ref _ref;
  StreamSubscription<PanelInbound>? _sub;

  /// What the panel has already been told about turns in flight.
  final _turns = PanelTurnMirror();

  /// Start answering. Safe to call twice — the second call is a no-op rather
  /// than a second subscription answering everything twice.
  ///
  /// Wired *before* the port is opened, not after: the panel says `hello` the
  /// moment it sees the port, and [PanelLink.messages] is a broadcast stream,
  /// so a message with no listener is dropped rather than buffered. A listener
  /// attached a frame late would miss the handshake and the link would sit
  /// there looking connected and silent.
  void listen() {
    _sub ??= _ref.read(panelLinkProvider).messages.listen(_answer);
  }

  /// Stop answering. The link and the port are released by their own providers.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _answer(PanelInbound message) async {
    switch (message) {
      case PanelHello():
        await _welcome(message);
      case PanelProjectsRequested():
        _sendProjects();
      case PanelStopRequested(:final projectId):
        _stopProject(projectId);
      case PanelTurnRequested(:final projectId, :final text):
        _startTurn(projectId, text);
      case PanelUnknown(:final type):
        _log.warn('panel', 'Panel sent "$type", which this build cannot read');
      case PanelMalformed(:final reason):
        _log.warn('panel', 'Unreadable message from the panel: $reason');
    }
  }

  /// Answer the panel's introduction, and say which machine it is looking at —
  /// on this link simply the computer it is plugged into.
  Future<void> _welcome(PanelHello hello) async {
    _log.info(
      'panel',
      'Panel ${hello.mac} said hello '
          '(firmware ${hello.firmware}, protocol ${hello.protocol})',
    );
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
          ),
        );
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
  }

  /// Tell the panel whatever has changed about the turns in flight.
  ///
  /// Called on every chat-state and run-feed change, which is often — a turn
  /// publishes a phase per streamed token. [PanelTurnMirror] is what makes that
  /// affordable: it says nothing when nothing the panel can draw has moved.
  void mirrorTurns() => _push(
    _turns.onChange(
      projects: _ref.read(sortedProjectsProvider),
      chats: _ref.read(chatSessionsProvider),
      runs: _ref.read(agentRunsProvider),
    ),
  );

  void _push(List<String> messages) {
    if (messages.isEmpty) return;
    final link = _ref.read(panelLinkProvider);
    for (final message in messages) {
      link.send(message);
    }
  }

  /// Send the tiles: every project, in the order the app itself lists them, so
  /// the panel and the rail never disagree about which project is first.
  void _sendProjects() {
    final tiles = panelProjectsFor(
      projects: _ref.read(sortedProjectsProvider),
      chats: _ref.read(chatSessionsProvider),
    );
    _ref.read(panelLinkProvider).send(PanelOutbound.projects(tiles));
  }

  /// Interrupt whatever is running in [projectId].
  ///
  /// Every conversation in the project, not one: the panel names a project
  /// because a project is what its tile is, and which chat inside it holds the
  /// turn is the desktop's business — a project can also have a second chat
  /// queued behind the running one, and Stop means stop.
  /// [ChatSessionsController.stopChat] is a no-op on a chat with nothing in
  /// flight, so this costs nothing when the tile was already idle.
  void _stopProject(String projectId) {
    final chats = _ref.read(chatSessionsProvider);
    final controller = _ref.read(chatSessionsProvider.notifier);
    for (final conversation in chats.live) {
      if (conversation.projectId != projectId) continue;
      controller.stopChat(conversation.id);
    }
  }

  /// Start a turn the user asked for on the panel.
  ///
  /// It goes into the project's most recently used chat, or a new one when
  /// nobody has talked there yet — the same place the window would put it, so
  /// the two screens show one conversation rather than two histories of the
  /// same work.
  ///
  /// Every way this can fail is answered in words. Silence would leave the tile
  /// spinning on work that is never coming, and the panel has no other way to
  /// find out: it runs no model, reads no disk and cannot see the window.
  void _startTurn(String projectId, String text) {
    final asked = text.trim();
    if (asked.isEmpty) {
      _refuseTurn(projectId, 'That arrived with no words in it. Say it again?');
      return;
    }
    final project = _ref.read(projectByIdProvider(projectId));
    if (project == null) {
      _refuseTurn(projectId, 'This computer no longer has that project.');
      return;
    }

    final chats = _ref.read(chatSessionsProvider);
    final conversations = _conversationsIn(projectId, chats);
    if (conversations.any((c) => panelTurnInFlight(chats, c.id))) {
      _refuseTurn(
        projectId,
        'That project is already working. Press stop first, or wait for it.',
      );
      return;
    }

    // Read before the model: with no grid there is nothing to serve a model
    // either, and "pick a grid" is the step that unblocks both.
    final network = _ref.read(selectedNetworkProvider);
    if (network == null) {
      _refuseTurn(
        projectId,
        'No grid is open on this computer. Open Grid and pick one.',
      );
      return;
    }

    final target = conversations.isEmpty ? null : conversations.first;
    final model = _modelFor(project, target);
    if (model.isEmpty) {
      _refuseTurn(
        projectId,
        'No model is available on this grid. Start one in Grid, then try again.',
      );
      return;
    }

    _log.info('panel', 'Panel started a turn in ${project.name}');
    unawaited(_dispatchTurn(projectId, target, network, model, asked));
  }

  /// Hand the turn to [ChatSessionsController] and report a start that never
  /// got off the ground.
  ///
  /// Not awaited by the caller: `send` completes when the *turn* does, which is
  /// minutes for an agent, and the panel's next message (Stop, most of all)
  /// must not queue behind it. Everything after this point reaches the panel
  /// through [mirrorTurns] instead.
  Future<void> _dispatchTurn(
    String projectId,
    Conversation? target,
    NetworkCredential network,
    String model,
    String text,
  ) async {
    final chats = _ref.read(chatSessionsProvider.notifier);
    try {
      if (target != null) {
        await chats.send(
          network: network,
          model: model,
          message: text,
          into: target.id,
        );
        return;
      }
      // A project nobody has talked in yet has no chat to send into, and a
      // chat is not saved until its first message — so it has to be composed
      // first. This does open it in the window, unlike every other send the
      // app makes on its own: the user did ask for this, just from the other
      // side of the desk, and a reply landing in a chat the window never shows
      // is a reply they have to go hunting for.
      chats.newChat(projectId: projectId);
      await chats.send(network: network, model: model, message: text);
    } on Object catch (e) {
      _log.warn('panel', 'Panel turn in $projectId could not start: $e');
      _refuseTurn(
        projectId,
        "That couldn't be started here. Open Grid to see.",
      );
    }
  }

  /// The project's chats, most recently used first.
  ///
  /// Sorted here rather than trusting [ChatSessionsState.live]'s order, which
  /// floats pinned chats to the top — right for a sidebar the user clicks, and
  /// wrong for "where does the next thing said here belong".
  List<Conversation> _conversationsIn(String projectId, ChatSessionsState c) =>
      [
        for (final conversation in c.live)
          if (conversation.projectId == projectId) conversation,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

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
  void _refuseTurn(String projectId, String message) {
    _log.warn('panel', 'Panel turn in $projectId refused: $message');
    _ref
        .read(panelLinkProvider)
        .send(PanelOutbound.turnError(projectId: projectId, message: message));
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

/// The panel's view of [projects] — one tile each, in the order given.
///
/// Pure, and the one place the app's state becomes the panel's: a tile is
/// derived, never stored, so nothing can go stale between the two screens.
List<PanelProject> panelProjectsFor({
  required List<Project> projects,
  required ChatSessionsState chats,
}) => [for (final project in projects) panelProjectFor(project, chats)];

/// One project as a tile: its name, which assistant answers in it, whether it
/// is working right now, and one line of what was last said there.
///
/// Thin on purpose — the panel is 480px across. Instructions, memory and the
/// workspace path stay in the app.
PanelProject panelProjectFor(Project project, ChatSessionsState chats) {
  final conversations = [
    for (final conversation in chats.live)
      if (conversation.projectId == project.id) conversation,
  ];
  return PanelProject(
    id: project.id,
    name: project.name,
    agent: project.agent,
    model: project.model,
    // Any of the project's chats, not just the newest: turns are serialized per
    // project, so the one holding the lane is what makes the tile busy, and it
    // is not necessarily the chat the recap came from.
    //
    // The same test the pushed turn state uses ([panelTurnInFlight]) — a tile
    // that says idle while `turn.started` is on its way about the same project
    // is two answers to one question.
    busy: conversations.any((c) => panelTurnInFlight(chats, c.id)),
    recap: _recapOf(conversations),
  );
}

/// The last thing the assistant said in the project's most recently used chat,
/// cut to one line.
///
/// Sorted here rather than trusting the order [ChatSessionsState.live] comes
/// in: that one floats pinned chats to the top, which is right for a sidebar
/// the user clicks and wrong for "what happened here last".
///
/// Empty when nothing has been said yet — [PanelProject] then leaves the field
/// out rather than sending a blank one.
String _recapOf(List<Conversation> conversations) {
  if (conversations.isEmpty) return '';
  final newest = [...conversations]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return panelRecapOf(newest.first);
}
