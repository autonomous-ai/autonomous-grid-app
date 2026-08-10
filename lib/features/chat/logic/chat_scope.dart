import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../projects/logic/project.dart';
import 'chat_sessions_controller.dart';

/// Where the chat on screen keeps its two "what answers me" choices — the
/// assistant and the model — and who they belong to.
///
/// A chat inside a project answers with **that project's** assistant and model;
/// a chat outside every project answers with the app's standing choice
/// ([ChatPrefs]). One app-wide pair was the wrong shape for how people work: a
/// Flutter repo wants Claude Code on a coding model, a folder of notes wants
/// Hermes on a small local one, and with one setting between them every switch
/// was a re-pick the user had to remember to make — or a turn answered by the
/// wrong assistant on the wrong model.
///
/// The project is resolved through [ChatSessionsState.openProjectId], so a
/// not-yet-saved chat being composed inside a project already counts as being in
/// it — the composer must show what the *next* message will run on, not what the
/// last saved chat ran on.

/// The project the chat on screen belongs to, or null for a plain chat.
final openChatProjectIdProvider = Provider<String?>(
  (ref) => ref.watch(chatSessionsProvider.select((s) => s.openProjectId)),
);

/// That project, or null when the chat belongs to none (or it was removed while
/// a chat inside it stayed open).
final openChatProjectProvider = Provider<Project?>(
  (ref) => ref.watch(projectByIdProvider(ref.watch(openChatProjectIdProvider))),
);

/// The model the chat on screen starts on — the open project's own when it has
/// picked one, else the app's standing choice. Null until anything has been
/// picked at all, which the composer reads as "use this grid's first model".
final chatScopeModelProvider = Provider<String?>(
  (ref) =>
      ref.watch(openChatProjectProvider)?.model ??
      ref.watch(chatPrefsProvider.select((p) => p.model)),
);

/// Writes a pick to whichever of the two remembers it. The read side is
/// [chatScopeModelProvider] and `chatAgentChoiceProvider`; this is the one place
/// that decides *where* a pick lands, so the composer, the Agents screen and the
/// hand-over bar can't drift into saving it in different places.
class ChatScopePrefs {
  const ChatScopePrefs(this._ref);

  final Ref _ref;

  /// Remember [agentId] (an `AgentTool` id) for the open chat's project, or as
  /// the app's standing choice when the chat belongs to no project.
  void setAgent(String agentId) => _write(
    project: (projects, id) => projects.setAgent(id, agentId),
    app: (prefs) => prefs.setChatAgent(agentId),
  );

  /// Remember [model] the same way — the model half of the same decision.
  void setModel(String model) => _write(
    project: (projects, id) => projects.setModel(id, model),
    app: (prefs) => prefs.setModel(model),
  );

  /// Routed by the project the open chat *still has* ([openChatProjectProvider])
  /// rather than the id it carries: a chat can outlive the project it was
  /// started in, and writing to a project that is gone would drop the pick on
  /// the floor — the user would press it and nothing at all would happen.
  void _write({
    required void Function(ProjectsController projects, String id) project,
    required void Function(ChatPrefsController prefs) app,
  }) {
    final open = _ref.read(openChatProjectProvider);
    if (open == null) {
      app(_ref.read(chatPrefsProvider.notifier));
      return;
    }
    project(_ref.read(projectsProvider.notifier), open.id);
  }
}

final chatScopePrefsProvider = Provider<ChatScopePrefs>(ChatScopePrefs.new);
