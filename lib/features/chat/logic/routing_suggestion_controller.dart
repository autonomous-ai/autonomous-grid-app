import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/network_models_provider.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/one_shot_target.dart' show friendlyOneShotError;
import 'routing_group.dart';

/// How the grid answered [RoutingSuggestionController.fetchSuggestion] — a
/// real chat completion, so it takes a moment and can fail like any other
/// turn.
sealed class RoutingSuggestionState {
  const RoutingSuggestionState();
}

/// The probe is in flight, or hasn't been sent yet.
class RoutingSuggestionLoading extends RoutingSuggestionState {
  const RoutingSuggestionLoading();
}

/// The grid answered with a suggestion the setup dialog can preview.
class RoutingSuggestionReady extends RoutingSuggestionState {
  const RoutingSuggestionReady(this.group);
  final RoutingGroup group;
}

/// The probe couldn't be sent, or the answer couldn't be read as a
/// suggestion — [reason] is safe to show the user verbatim.
class RoutingSuggestionFailed extends RoutingSuggestionState {
  const RoutingSuggestionFailed(this.reason);
  final String reason;
}

/// Drives the routing setup dialog's suggestion step (design spec §3): asks
/// the grid's own `auto` router which models it would pick for a routing
/// mode, given what this chat has been about so far.
///
/// One real, billed `chat/completions` call, reusing the shared
/// [ChatTransport] the way `ChatTitleWriter`/`SkillGenerator` do for their own
/// one-off completions — sent to the *grid's relay specifically* (never the
/// local engine `resolveOneShotTarget` would prefer) because Brute Force and
/// Feedback Loop are grid-only orchestration patterns with nothing for a local
/// engine to route between.
final routingSuggestionControllerProvider =
    NotifierProvider.autoDispose<
      RoutingSuggestionController,
      RoutingSuggestionState
    >(RoutingSuggestionController.new);

class RoutingSuggestionController extends Notifier<RoutingSuggestionState> {
  @override
  RoutingSuggestionState build() => const RoutingSuggestionLoading();

  /// Asks the grid to suggest models for [mode], summarizing [conversation]
  /// (the chat's turns so far, oldest first) into the probe so the pick fits
  /// what's actually being discussed. Safe to call again — a "Try again"
  /// after a failure just re-sends the probe.
  Future<void> fetchSuggestion(
    RoutingMode mode, {
    List<ChatMessage> conversation = const [],
  }) async {
    state = const RoutingSuggestionLoading();

    final network = ref.read(selectedNetworkProvider);
    if (network == null) {
      state = const RoutingSuggestionFailed(
        'Pick a grid before setting up routing.',
      );
      return;
    }

    final models = await ref.read(networkModelsProvider.future);
    // Cancel (closing the dialog) while the models list is still loading is
    // ordinary — this notifier is autoDispose with only the dialog watching
    // it, so it may already be gone by the time this resumes.
    if (!ref.mounted) return;
    if (models.length < 2) {
      state = const RoutingSuggestionFailed(
        "This grid isn't serving enough models to route between yet.",
      );
      return;
    }

    final messages = _probePrompt(mode, conversation, models);
    final log = ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${network.relayBaseUrl}/chat/completions',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: 'auto', messages: messages),
        authorized: network.relayApiKey.isNotEmpty,
      ),
    );
    final (reply, error) = await ref
        .read(chatTransportProvider)
        .complete(
          endpoint: '${network.relayBaseUrl}/chat/completions',
          apiKey: network.relayApiKey,
          model: 'auto',
          messages: messages,
        );
    // The probe is a real request that can take up to 180s — Cancel while
    // it's in flight disposes this notifier (same reasoning as above), and
    // the call must not touch `state` or the log after that.
    if (!ref.mounted) return;
    log.finish(
      id,
      exitCode: error?.statusCode ?? 200,
      error: error?.message,
      responseBody: reply,
    );

    if (error != null) {
      state = RoutingSuggestionFailed(
        friendlyOneShotError(error, what: 'suggest models'),
      );
      return;
    }

    final parsed = parseSuggestion(reply ?? '', mode);
    state = switch (parsed) {
      SuggestionParsed(:final group) => RoutingSuggestionReady(group),
      SuggestionParseFailed(:final reason) => RoutingSuggestionFailed(reason),
    };
  }
}

/// How much of one turn's text the probe is shown. This decides *which*
/// models fit a conversation, not what to say in it — the gist is enough, and
/// a long turn would spend most of the probe's context on prose that has
/// nothing to do with routing.
const int _kMaxTurnChars = 400;

/// How many of the most recent turns are summarized. Recent context is what a
/// routing pick actually needs — the topic three turns ago has usually moved
/// on by the time Fixed mode is set up.
const int _kMaxTurns = 6;

/// The probe sent as the whole `messages` array (design spec §3): a system
/// message naming the task, the models this grid actually serves, and the
/// exact JSON shape to answer in; a user message summarizing the conversation.
List<Map<String, dynamic>> _probePrompt(
  RoutingMode mode,
  List<ChatMessage> conversation,
  List<String> models,
) {
  final summary = _summarize(conversation);
  final shape = switch (mode) {
    RoutingMode.bruteForce => '{"models":["model-a","model-b","model-c"]}',
    RoutingMode.judgeLoop => '{"worker":"model-a","judge":"model-b"}',
  };
  final task = switch (mode) {
    RoutingMode.bruteForce =>
      'Pick 2 to 4 of the models below to answer this chat in parallel — '
          'the strongest few for what it needs, not just the first ones '
          'listed.',
    RoutingMode.judgeLoop =>
      'Pick one model from the list to draft answers ("worker") and a '
          'different model to grade drafts and ask for revisions ("judge").',
  };
  return [
    {
      'role': 'system',
      'content':
          'You are choosing which models power an AI grid chat. $task\n'
          'Reply with ONLY a JSON object — no prose, no code fence — shaped '
          'exactly like $shape. Use only model ids from this list, '
          'verbatim:\n${models.join(', ')}',
    },
    {
      'role': 'user',
      'content': summary.isEmpty
          ? 'This is a new chat — nothing has been said yet.'
          : 'What this chat has been about so far:\n$summary',
    },
  ];
}

/// The last [_kMaxTurns] non-empty turns as "Who: text" lines, each turn cut
/// to [_kMaxTurnChars]. Empty for a conversation with nothing said yet.
String _summarize(List<ChatMessage> conversation) {
  final turns = <String>[];
  for (final message in conversation) {
    final text = message.text.trim();
    if (text.isEmpty) continue;
    final who = message.role == ChatRole.user ? 'User' : 'Assistant';
    turns.add('$who: ${_trimTurn(text)}');
  }
  final recent = turns.length > _kMaxTurns
      ? turns.sublist(turns.length - _kMaxTurns)
      : turns;
  return recent.join('\n\n');
}

String _trimTurn(String text) => text.length <= _kMaxTurnChars
    ? text
    : '${text.substring(0, _kMaxTurnChars)} […]';
