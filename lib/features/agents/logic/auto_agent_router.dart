import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../auth/logic/session_controller.dart';
import '../../chat/logic/chat_scope.dart';
import '../../network/logic/node_display.dart' show kAutoModelId;
import '../../playground/logic/one_shot_target.dart';
import '../../playground/logic/playground_models.dart';
import 'active_chat_agent.dart';
import 'agent_catalog.dart';
import 'agent_grid_support.dart';
import 'agent_status.dart';
import 'auto_agent.dart';

/// Whether the chats in [projectId] are set to **Auto** — the stored choice is
/// the [kAutoAgentId] sentinel rather than a real agent id.
///
/// Read at send time to decide whether to route, and by the picker to show Auto
/// as the current choice.
final isAutoAgentChosenForProjectProvider = Provider.family<bool, String?>(
  (ref, projectId) =>
      isAutoAgentId(ref.watch(chatAgentChoiceProvider(projectId))),
);

/// Whether the chat **on screen** is set to Auto.
final isAutoAgentChosenProvider = Provider<bool>(
  (ref) => ref.watch(
    isAutoAgentChosenForProjectProvider(ref.watch(openChatProjectIdProvider)),
  ),
);

/// The installed agents this grid can actually run — the pool Auto chooses from.
///
/// Both bars, the same ones [chatAgentForProjectProvider] uses: an agent the
/// user removed can't answer, and neither can one this grid serves no model
/// for. Watched so the pool follows an install finishing or a grid switch.
final runnableChatAgentsProvider = Provider<List<AgentTool>>((ref) {
  return [
    for (final tool in AgentTool.values)
      if (ref.watch(agentInstalledProvider(tool)) &&
          ref.watch(agentRunsOnGridProvider(tool)))
        tool,
  ];
});

/// Picks the installed assistant best suited to a question, by asking the grid.
///
/// The Auto agent's brain. It sends the question and each candidate's strengths
/// to the grid's auto model (a one-shot `chat/completions`) and reads back a
/// single agent id. Everything about it degrades to a real answer rather than a
/// failure: one candidate needs no call, an unreachable grid or an unreadable
/// reply falls to a keyword [heuristicRoute], and the pure decision lives in
/// [auto_agent.dart] so it is tested without a network.
final autoAgentRouterProvider = Provider<AutoAgentRouter>(AutoAgentRouter.new);

class AutoAgentRouter {
  const AutoAgentRouter(this._ref);

  final Ref _ref;

  /// How long the classifier is given before the turn goes ahead without it.
  /// Short on purpose: this runs *before* the user sees any answer, so a slow
  /// grid must not hold the whole turn hostage — the heuristic is a fine
  /// second, and a routed turn a second late reads as the turn simply starting.
  static const _timeout = Duration(seconds: 8);

  /// The agent to answer [question] with, chosen from [candidates].
  ///
  /// Never throws and never returns something outside [candidates]: the caller
  /// dispatches straight to whatever comes back.
  Future<AgentTool> route({
    required String question,
    required List<AgentTool> candidates,
  }) async {
    if (candidates.isEmpty) return AgentTool.hermes;
    if (candidates.length == 1) return candidates.first;

    final log = _ref.read(appLogProvider);
    final target = _classifierTarget();
    if (target == null) {
      final picked = heuristicRoute(question, candidates);
      log.info('agent', 'Auto (no grid model to ask): ${picked.id}');
      return picked;
    }

    final (reply, error) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: buildRouterMessages(question, candidates),
        )
        .timeout(
          _timeout,
          onTimeout: () =>
              (null, const ChatTransportError('routing timed out')),
        );

    if (error != null || reply == null) {
      final picked = heuristicRoute(question, candidates);
      log.warn(
        'agent',
        'Auto routing failed (${error?.message ?? 'no reply'}); '
            'falling back to ${picked.id}',
      );
      return picked;
    }

    final routed = parseRoutedAgent(reply, candidates);
    if (routed != null) {
      log.info(
        'agent',
        'Auto routed to ${routed.id} for: '
            '${_snippet(question)}',
      );
      return routed;
    }
    // The grid answered, but with nothing this app could pin to a candidate.
    final picked = heuristicRoute(question, candidates);
    log.info(
      'agent',
      'Auto reply unreadable ("${_snippet(reply)}"); '
          'falling back to ${picked.id}',
    );
    return picked;
  }

  /// Where to send the classifier, preferring the grid's auto model.
  ///
  /// The user's own words for this feature — "call via grid url + auto model" —
  /// so when the selected grid serves the `auto` router that is what asks. When
  /// it doesn't (a grid with no auto-routing), any working text model answers
  /// the question just as well, so the shared [resolveOneShotTarget] fills in.
  OneShotTarget? _classifierTarget() {
    final network = _ref.read(selectedNetworkProvider);
    final servesAuto = _ref
        .read(playgroundModelsProvider)
        .any((option) => option.id == kAutoModelId);
    if (network != null && servesAuto) {
      return (
        endpoint: '${network.relayBaseUrl}/chat/completions',
        apiKey: network.relayApiKey,
        model: kAutoModelId,
      );
    }
    return resolveOneShotTarget(_ref);
  }

  static String _snippet(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 80 ? one : '${one.substring(0, 79)}…';
  }
}
