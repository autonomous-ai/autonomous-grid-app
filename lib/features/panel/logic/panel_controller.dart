import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text_preview.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/panel/panel_link.dart';
import '../../../infrastructure/panel/panel_link_provider.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../../shared/app_info.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
import '../../projects/logic/project.dart';
import '../../provider_node/logic/provider_run_controller.dart';

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
  ref.onDispose(controller.stop);
  return controller;
});

/// Answers the panel over [panelLinkProvider].
class PanelController {
  PanelController(this._ref);

  final Ref _ref;
  StreamSubscription<PanelInbound>? _sub;

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
      case PanelTurnRequested(:final projectId):
        _refuseTurn(projectId);
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

  /// Tell the panel a turn typed on it cannot be sent yet.
  ///
  /// Silence is the wrong answer: the tile would spin on a turn that is never
  /// coming. Sending turns from the panel is the next milestone — until then
  /// this says so, in words, on the screen the user is looking at.
  void _refuseTurn(String projectId) {
    _log.warn('panel', 'Panel asked to start a turn — not built yet');
    _ref
        .read(panelLinkProvider)
        .send(
          PanelOutbound.turnError(
            projectId: projectId,
            message: 'This computer can\'t start work from the panel yet.',
          ),
        );
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
    busy: conversations.any((c) => chats.agentRunningIn(c.id)),
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
  for (final message in newest.first.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    final text = message.text.trim();
    if (text.isNotEmpty) return firstLinePreview(text);
  }
  return '';
}
