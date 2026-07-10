import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/relay_api_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';

/// Models advertised on the selected network, via the relay's OpenAI-style
/// `GET {relayBaseUrl}/models` (the `inference:models` scope).
///
/// Returns empty — never throws — when no provider is online, the token lacks
/// the inference scope, or the relay is unreachable. Callers (the Playground's
/// model picker, the grid overview's node list) keep a graceful fallback in
/// those cases so the UI never blanks out. The HTTP itself lives in
/// [RelayApiClient]; this provider only orchestrates and logs the call.
final networkModelsProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return const [];

  final log = ref.read(commandLogProvider.notifier);
  final client = ref.read(relayApiClientProvider);
  final id = log.begin(CliCallKind.http, 'GET ${network.relayBaseUrl}/models');
  try {
    final ids = await client.models(
      baseUrl: network.relayBaseUrl,
      apiKey: network.relayApiKey,
    );
    log.finish(id, exitCode: 200);
    return ids;
  } on RelayUnavailable catch (e) {
    log.finish(
      id,
      exitCode: e.statusCode,
      error: e.statusCode == null ? '${e.cause ?? 'unreachable'}' : null,
    );
    return const [];
  }
});
