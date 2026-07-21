import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/relay_api_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';
import 'node_display.dart';

/// Models a grid serves, via the relay's OpenAI-style `GET {relayBaseUrl}/models`
/// (the `inference:models` scope). Keyed by network id so every grid in the
/// picker can be probed in parallel, independent of which one is selected.
///
/// This is the **canonical list of what you can chat with**: what the relay
/// serves, including the `auto` auto-routing model (ADR 0013) that the
/// node-derived `/grid/overview` leaves out — except when `auto` is the *only*
/// thing on the list. A grid with nothing but the router has nothing to route
/// to, so it reads as empty here rather than offering a model that answers
/// nothing. Filtering at the source ([answerableModels]) keeps the chat picker,
/// the playground, the messaging bot and every "no model yet" state agreeing.
///
/// Returns empty — never throws — when no provider is online, the token lacks the
/// inference scope, or the relay is unreachable, so the UI never blanks out.
final networkModelsForProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, networkId) async {
      final match = ref
          .watch(sessionProvider)
          .networks
          .where((n) => n.networkId == networkId);
      if (match.isEmpty) return const [];
      final network = match.first;

      final log = ref.read(commandLogProvider.notifier);
      final client = ref.read(relayApiClientProvider);
      final id = log.begin(
        CliCallKind.http,
        'GET ${network.relayBaseUrl}/models',
      );
      try {
        final ids = await client.models(
          baseUrl: network.relayBaseUrl,
          apiKey: network.relayApiKey,
        );
        log.finish(id, exitCode: 200);
        return answerableModels(ids);
      } on RelayUnavailable catch (e) {
        log.finish(
          id,
          exitCode: e.statusCode,
          error: e.statusCode == null ? '${e.cause ?? 'unreachable'}' : null,
        );
        return const [];
      }
    });

/// The selected grid's served models — [networkModelsForProvider] bound to
/// whichever grid is open. Kept as its own name because several callers only
/// ever care about the current grid.
final networkModelsProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return const [];
  return ref.watch(networkModelsForProvider(network.networkId).future);
});
