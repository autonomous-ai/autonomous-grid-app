import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';

/// Models advertised on the selected network, via the relay's OpenAI-style
/// `GET {relayBaseUrl}/models` (the `inference:models` scope).
///
/// Returns empty — never throws — when no provider is online, the token lacks
/// the inference scope, or the relay is unreachable. The Playground keeps an
/// editable field in those cases so the user can still type a model name.
final networkModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return const [];
  return _fetchModels(network.relayBaseUrl, network.relayApiKey);
});

Future<List<String>> _fetchModels(String relayBaseUrl, String apiKey) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse('$relayBaseUrl/models'))
        .timeout(const Duration(seconds: 3));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final response = await request.close().timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return const [];
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['data'] is! List) return const [];
    return (decoded['data'] as List)
        .whereType<Map>()
        .map((m) => '${m['id']}')
        .where((id) => id.isNotEmpty)
        .toList();
  } on Object {
    return const [];
  } finally {
    client.close(force: true);
  }
}
