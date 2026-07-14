import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/hermes_permission_policy.dart';
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

/// The one thing the agent is waiting on the user for, or null when it isn't
/// waiting on anything. The chat pins it above the composer: the agent has
/// stopped mid-answer and nothing happens until this is answered.
final agentPermissionProvider =
    NotifierProvider<AgentPermissionController, AgentPermission?>(
      AgentPermissionController.new,
    );

class AgentPermissionController extends Notifier<AgentPermission?> {
  Timer? _expiry;

  /// How to send the answer back to the agent — held here rather than in the
  /// state so the UI can't reach the transport.
  void Function(String? optionId)? _respond;

  @override
  AgentPermission? build() {
    ref.onDispose(_stopWaiting);
    return null;
  }

  /// Put [request] to the user. [respond] answers the agent with the option id
  /// they chose (or null to cancel, which the agent reads as no).
  void ask(AgentPermission request, void Function(String? optionId) respond) {
    _stopWaiting();
    _respond = respond;
    state = request;
    _expiry = Timer(
      ref.read(agentPermissionTimeoutProvider),
      () => answer(AgentPermissionChoice.refuse),
    );
  }

  /// The user answered. Sends it, and — when the answer is no — leaves a line in
  /// the activity feed, so a refusal is visible afterwards instead of the agent
  /// simply failing to do what was asked.
  void answer(AgentPermissionChoice choice) {
    final request = state;
    final respond = _respond;
    if (request == null || respond == null) return;

    _stopWaiting();
    state = null;
    respond(optionIdForChoice(choice, request.options));

    if (choice != AgentPermissionChoice.refuse) return;
    ref
        .read(agentActivityProvider.notifier)
        .upsert(
          AgentActivity(
            id: 'refused-${request.id}',
            kind: AgentActivityKind.command,
            label: 'You said no: ${_label(request)}',
            status: AgentActivityStatus.failed,
          ),
        );
  }

  /// The turn ended or was stopped — there's nobody left to answer.
  void clear() {
    if (state == null && _respond == null) return;
    _stopWaiting();
    state = null;
  }

  void _stopWaiting() {
    _expiry?.cancel();
    _expiry = null;
    _respond = null;
  }

  String _label(AgentPermission request) => switch (request.kind) {
    AgentPermissionKind.command => request.command ?? 'run a command',
    AgentPermissionKind.edit => request.path ?? 'change a file',
  };
}
