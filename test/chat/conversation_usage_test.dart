import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation_usage.dart';
import 'package:grid_app/features/chat/logic/turn_model_share.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/api/relay_api_client.dart';

/// Records the `usage()` query it was called with, so a test can assert on
/// exactly what [fetchTurnUsage] asked the relay for — not just that some
/// call happened. `models`/`overview`/`memberUsage` are never exercised by
/// [fetchTurnUsage], so they throw if a future caller starts relying on them.
class _FakeRelayApiClient implements RelayApiClient {
  _FakeRelayApiClient(this.response);

  final ConversationUsage response;
  Map<String, dynamic>? lastQuery;

  @override
  Future<ConversationUsage> usage({
    required String baseUrl,
    required String apiKey,
    DateTime? since,
    DateTime? until,
    String? conversation,
    String? from,
    String? to,
  }) async {
    lastQuery = {'conversation': conversation, 'from': from, 'to': to};
    return response;
  }

  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) => throw UnimplementedError();

  @override
  Future<GridOverview> overview({
    required String baseUrl,
    required String apiKey,
  }) => throw UnimplementedError();

  @override
  Future<MemberUsageReport?> memberUsage({
    required String baseUrl,
    required String apiKey,
  }) => throw UnimplementedError();
}

void main() {
  test('first turn of a conversation omits from', () async {
    final fake = _FakeRelayApiClient((
      models: const <ModelShare>[],
      last: 'wm-1',
    ));
    final result = await fetchTurnUsage(
      client: fake,
      baseUrl: 'https://relay.example',
      apiKey: 'k',
      conversationId: 'conv-1',
      from: null,
    );
    expect(fake.lastQuery!['conversation'], 'conv-1');
    expect(fake.lastQuery!['from'], isNull);
    expect(result.last, 'wm-1');
  });

  test('later turns pass the stored watermark as from', () async {
    final fake = _FakeRelayApiClient((
      models: const <ModelShare>[],
      last: 'wm-2',
    ));
    await fetchTurnUsage(
      client: fake,
      baseUrl: 'https://relay.example',
      apiKey: 'k',
      conversationId: 'conv-1',
      from: 'wm-1',
    );
    expect(fake.lastQuery!['conversation'], 'conv-1');
    expect(fake.lastQuery!['from'], 'wm-1');
    expect(fake.lastQuery!['to'], isNull);
  });
}
