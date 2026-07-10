import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../auth/logic/session_controller.dart';

/// Models advertised on the selected network, via the relay's OpenAI-style
/// `GET {relayBaseUrl}/models` (the `inference:models` scope).
///
/// Returns empty — never throws — when no provider is online, the token lacks
/// the inference scope, or the relay is unreachable. Callers (the Playground's
/// model picker, the grid overview's node list) keep a graceful fallback in
/// those cases so the UI never blanks out.
final networkModelsProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return const [];
  final log = ref.read(commandLogProvider.notifier);
  return _fetchModels(log, network.relayBaseUrl, network.relayApiKey);
});

Future<List<String>> _fetchModels(
  CommandLogNotifier log,
  String relayBaseUrl,
  String apiKey,
) async {
  final url = '$relayBaseUrl/models';
  final logId = log.begin(CliCallKind.http, 'GET $url');
  var logged = false;
  void done({int? status, String? error}) {
    if (logged) return;
    logged = true;
    log.finish(logId, exitCode: status, error: error);
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 3));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final response = await request.close().timeout(const Duration(seconds: 4));
    final body = await response.transform(utf8.decoder).join();
    done(status: response.statusCode);
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['data'] is! List) return const [];
    return (decoded['data'] as List)
        .whereType<Map>()
        .map((m) => '${m['id']}')
        .where((id) => id.isNotEmpty)
        .toList();
  } on Object catch (e) {
    done(error: e.toString());
    return const [];
  } finally {
    client.close(force: true);
  }
}
