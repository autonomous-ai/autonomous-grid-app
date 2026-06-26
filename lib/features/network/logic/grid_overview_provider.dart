import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';

/// Live overview of the selected grid, via `GET {relayBaseUrl}/grid/overview`
/// authorized with that grid's `access_token`. Auto-disposes and refetches
/// whenever the selected grid changes — i.e. every time you open a grid.
///
/// Throws [GridOverviewUnavailable] (never a raw socket error) so the detail
/// pane can render a clean "offline" state instead of a stack trace.
final gridOverviewProvider =
    FutureProvider.autoDispose<GridOverview>((ref) async {
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) {
    throw const GridOverviewUnavailable('No grid selected.');
  }
  return _fetchOverview(network);
});

class GridOverviewUnavailable implements Exception {
  const GridOverviewUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<GridOverview> _fetchOverview(NetworkCredential network) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .getUrl(Uri.parse('${network.relayBaseUrl}/grid/overview'))
        .timeout(const Duration(seconds: 4));
    request.headers
        .set(HttpHeaders.authorizationHeader, 'Bearer ${network.relayApiKey}');
    final response = await request.close().timeout(const Duration(seconds: 6));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw GridOverviewUnavailable(_reason(response.statusCode));
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const GridOverviewUnavailable('Malformed overview response.');
    }
    return GridOverview.fromJson(decoded.cast<String, dynamic>());
  } on GridOverviewUnavailable {
    rethrow;
  } on Object {
    throw const GridOverviewUnavailable('Grid is unreachable right now.');
  } finally {
    client.close(force: true);
  }
}

String _reason(int status) => switch (status) {
      503 => 'No node is online for this grid right now.',
      401 || 403 => 'Not authorized for this grid.',
      _ => 'Grid overview unavailable (HTTP $status).',
    };
