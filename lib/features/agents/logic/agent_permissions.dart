import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/hermes_permission_policy.dart';
import 'agent_changes.dart';
import 'agent_providers.dart';

/// How long the user gets to answer before the agent gives up on them.
///
/// Hermes stops waiting after a minute and takes silence as no; the app answers
/// a few seconds earlier so the outcome the user sees is the one that actually
/// happened, rather than a card that quietly stops meaning anything.
const Duration kAgentPermissionTimeout = Duration(seconds: 55);

/// Overridable so tests don't sit through the wait.
final agentPermissionTimeoutProvider = Provider<Duration>(
  (ref) => kAgentPermissionTimeout,
);

/// How long a turn may go silent — no message, no tool step — before the app
/// writes a line in the log saying so.
///
/// A note, not a verdict. It used to end the turn, on the theory that silence
/// meant the agent had wedged itself on a command that never returns. It also
/// looks exactly like a long `npm install`, a full test suite, or a slow local
/// model thinking, and the turns it cut were working — so the app no longer ends
/// a turn the agent hasn't ended. What the user sees is the working bubble's own
/// clock; Stop is theirs to press. This is only so the log can say afterwards
/// where the quiet started.
const Duration kAgentTurnIdleTimeout = Duration(minutes: 5);

/// Overridable so tests don't sit through the wait.
final agentTurnIdleTimeoutProvider = Provider<Duration>(
  (ref) => kAgentTurnIdleTimeout,
);

/// What each chat's agent is waiting on the user for, keyed by conversation —
/// absent when that chat isn't waiting on anything. The chat pins its own above
/// the composer: the agent has stopped mid-answer and nothing happens until this
/// is answered.
///
/// **Keyed, not one request.** Turns run at the same time in different projects,
/// and a single slot meant the second one to ask overwrote the first's way of
/// answering — leaving that chat hung on a card the user could no longer clear,
/// until its own timeout took silence as no.
final agentPermissionsProvider =
    NotifierProvider<AgentPermissionController, Map<String, AgentPermission>>(
      AgentPermissionController.new,
    );

/// What [chatId] is waiting on, or null when it isn't waiting — what one chat's
/// permission card reads.
final agentPermissionProvider = Provider.autoDispose
    .family<AgentPermission?, String?>(
      (ref, chatId) =>
          chatId == null ? null : ref.watch(agentPermissionsProvider)[chatId],
    );

class AgentPermissionController extends Notifier<Map<String, AgentPermission>> {
  /// The countdown and the way back to the agent, per chat — held here rather
  /// than in the state so the UI can't reach the transport.
  final Map<String, Timer> _expiry = {};
  final Map<String, void Function(String? optionId)> _respond = {};

  @override
  Map<String, AgentPermission> build() {
    ref.onDispose(() {
      for (final timer in _expiry.values) {
        timer.cancel();
      }
      _expiry.clear();
      _respond.clear();
    });
    return const {};
  }

  /// Put [request] to the user in [chatId]. [respond] answers the agent with the
  /// option id they chose (or null to cancel, which the agent reads as no).
  void ask(
    String chatId,
    AgentPermission request,
    void Function(String? optionId) respond,
  ) {
    _stopWaiting(chatId);
    _respond[chatId] = respond;
    state = Map.unmodifiable({...state, chatId: request});
    _expiry[chatId] = Timer(
      ref.read(agentPermissionTimeoutProvider),
      () => answer(chatId, AgentPermissionChoice.refuse),
    );
  }

  /// The user answered in [chatId]. Sends it, and — when the answer is no —
  /// leaves a line in that chat's feed, so a refusal is visible afterwards
  /// instead of the agent simply failing to do what was asked.
  void answer(String chatId, AgentPermissionChoice choice) {
    final request = state[chatId];
    final respond = _respond[chatId];
    if (request == null || respond == null) return;

    _stopWaiting(chatId);
    _drop(chatId);
    respond(optionIdForChoice(choice, request.options));

    if (choice != AgentPermissionChoice.refuse) {
      // The user approved a file edit — record it so it can be undone.
      if (request.kind == AgentPermissionKind.edit) {
        ref
            .read(agentChangesProvider.notifier)
            .record(
              chatId: chatId,
              path: request.path ?? '',
              before: request.oldText,
              after: request.newText ?? '',
            );
      }
      return;
    }
    ref
        .read(agentRunsProvider.notifier)
        .upsertStep(
          chatId,
          AgentActivity(
            id: 'refused-${request.id}',
            kind: AgentActivityKind.command,
            label: 'You said no: ${_label(request)}',
            status: AgentActivityStatus.failed,
          ),
        );
  }

  /// [chatId]'s turn ended or was stopped — there's nobody left to answer.
  void clear(String chatId) {
    if (!state.containsKey(chatId) && !_respond.containsKey(chatId)) return;
    _stopWaiting(chatId);
    _drop(chatId);
  }

  void _stopWaiting(String chatId) {
    _expiry.remove(chatId)?.cancel();
    _respond.remove(chatId);
  }

  void _drop(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = Map.unmodifiable({
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
    });
  }

  String _label(AgentPermission request) => switch (request.kind) {
    AgentPermissionKind.command => request.command ?? 'run a command',
    AgentPermissionKind.edit => request.path ?? 'change a file',
    // The agent's own title for the call — the only name we have for a tool
    // this app doesn't recognise.
    AgentPermissionKind.other => request.summary,
  };
}
