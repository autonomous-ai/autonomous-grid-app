import '../../../infrastructure/api/relay_api_client.dart';

/// Fetches exactly the per-model breakdown for one turn: everything the
/// relay logged for [conversationId] at or after [from] (the previous
/// turn's watermark, or null for a conversation's first tagged turn).
///
/// A thin wrapper over [RelayApiClient.usage] rather than a call site calling
/// it directly — it exists so the caller that runs after each turn settles
/// can be unit-tested against a fake [RelayApiClient] without a fake HTTP
/// layer underneath it.
Future<ConversationUsage> fetchTurnUsage({
  required RelayApiClient client,
  required String baseUrl,
  required String apiKey,
  required String conversationId,
  String? from,
}) {
  return client.usage(
    baseUrl: baseUrl,
    apiKey: apiKey,
    conversation: conversationId,
    from: from,
  );
}
