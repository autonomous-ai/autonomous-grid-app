import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import 'chat_transport.dart';
import 'playground_models.dart';
import 'playground_request.dart';

/// Where a one-shot `chat/completions` request can be answered, and with what.
typedef OneShotTarget = ({String endpoint, String apiKey, String model});

/// The model that can already answer, or null when none can.
///
/// The local engine first when one is serving: it costs nothing and needs no
/// network. Otherwise the selected grid's relay, and only if the grid actually
/// advertises a text model — a media model can't hold a conversation, so
/// resolving the grid at all would be pointless.
///
/// Shared rather than written twice. It was written twice: the skill generator
/// and the commit-message writer ask the same question, and the second copy
/// would have been the one that stopped agreeing with the first.
OneShotTarget? resolveOneShotTarget(Ref ref) {
  final localBaseUrl = ref.read(localProviderEndpointProvider);
  final localModel = ref.read(servingModelProvider);
  if (localBaseUrl != null && localModel != null && localModel.isNotEmpty) {
    return (
      endpoint: '$localBaseUrl/v1/chat/completions',
      apiKey: '',
      model: localModel,
    );
  }

  final model = _firstTextModel(ref);
  if (model == null) return null;
  final network = ref.read(selectedNetworkProvider);
  if (network == null) return null;
  return (
    endpoint: '${network.relayBaseUrl}/chat/completions',
    apiKey: network.relayApiKey,
    model: model,
  );
}

/// The first plain-text model advertised on the grid — media modes can't chat.
String? _firstTextModel(Ref ref) {
  for (final option in ref.read(playgroundModelsProvider)) {
    if (option.modality == PlaygroundModality.text) return option.id;
  }
  return null;
}

/// What to tell the user when a one-shot call failed, with [what] naming the
/// job in their words ("draft the skill", "write the message").
String friendlyOneShotError(ChatTransportError error, {required String what}) {
  if (error.statusCode == 401 || error.statusCode == 403) {
    return 'Your session expired — please sign in again.';
  }
  final detail = error.message.trim();
  if (detail.isEmpty) {
    return "Couldn't reach a model to $what. Make sure one is running, then "
        'try again.';
  }
  return "Couldn't $what: $detail";
}

/// The line for a machine with nothing to ask, with [what] as above.
String noModelReady(String what) =>
    'No model is ready to $what. Start an engine, or pick a grid with a model '
    'running, then try again.';
