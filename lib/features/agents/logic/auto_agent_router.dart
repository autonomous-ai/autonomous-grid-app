import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/node_display.dart' show kAutoModelId;
import '../../playground/logic/one_shot_target.dart';
import '../../playground/logic/playground_models.dart';
import 'active_chat_agent.dart';
import 'agent_catalog.dart';
import 'agent_model_support.dart';
import 'auto_agent.dart';

/// Whether the chat **on screen** is set to **Auto** — its choice is the
/// [kAutoAgentId] sentinel rather than a real agent id, *and* this build offers
/// Auto ([autoAgentIsOffered]).
///
/// Read off the chat's own choice, not its project's: a chat that started under
/// Auto goes on routing, and one that fixed a named agent must not — the picker
/// would say Codex while the grid re-picked somebody else per question. Send
/// asks the same question of the conversation it is sending into
/// ([autoAgentChosen]), which is the same rule for a turn that goes out long
/// after the user has moved on.
final isAutoAgentChosenProvider = Provider<bool>(
  (ref) => autoAgentChosen(ref.watch(openChatAgentChoiceProvider)),
);

/// The agents Auto may choose between for a turn that will be sent with
/// [model] — installed here, runnable on this grid, *and* able to answer with
/// the model the turn actually carries.
///
/// The first two bars are [canAnswerChatsHere], the same ones
/// [chatAgentForProjectProvider] uses. The third is the one Auto adds and had
/// to: the composer's wall is computed against the agent *it* resolved, so a
/// grid serving only `claude:opus` would let Auto hand the turn to Codex and
/// dead-end it at the relay with "no model Codex can use" — after sending, on a
/// pair the user never picked. On a grid serving `auto` this bar excludes
/// nobody, since every agent can be pointed at the router.
///
/// Keyed by the wire model so the pool is asked about the model that will be
/// sent, not the one showing in the composer. When no candidate clears the model
/// bar the runnable ones stand: Auto then picks as it did before and the turn
/// meets the composer's existing wall, which is a failure the user has seen and
/// the chat's notice explains — rather than a second, emptier one Auto invented.
final autoAgentCandidatesProvider = Provider.family<List<AgentTool>, String>((
  ref,
  model,
) {
  final runnable = [
    for (final tool in AgentTool.values)
      if (canAnswerChatsHere(ref, tool)) tool,
  ];
  final withModel = [
    for (final tool in runnable)
      if (agentSupportsModel(tool, model)) tool,
  ];
  return List.unmodifiable(withModel.isEmpty ? runnable : withModel);
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
    if (candidates.isEmpty) return kChatAgent;
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
    final servesAuto = _ref.read(gridServesAutoModelProvider);
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
