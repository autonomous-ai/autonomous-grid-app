import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/mcp/mcp_proxy.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/rest_entry.dart';

/// One thing a connected connector can do, named for a person rather than for a
/// model.
///
/// The provider's own name is kept in [name] because it is the identifier — it
/// is what appears in a transcript when an agent calls it, and matching what the
/// user saw here to what they see there is the point. [label] is that same name
/// made readable; see [humanizeToolName].
class ConnectorTool {
  const ConnectorTool({
    required this.name,
    required this.label,
    required this.description,
  });

  final String name;
  final String label;
  final String description;
}

/// Where a tool list came from, and what to say when there isn't one.
///
/// A sealed result rather than `List<ConnectorTool>?` plus an error string: the
/// three endings are genuinely different sentences on screen, and a nullable
/// list makes "the provider offers none" and "we could not ask" the same value.
sealed class ConnectorToolsResult {
  const ConnectorToolsResult();
}

/// The provider answered, and this is what it offers. May be empty — a real
/// answer meaning "this connector is signed in but does nothing yet".
class ConnectorToolsLoaded extends ConnectorToolsResult {
  const ConnectorToolsLoaded(this.tools);

  final List<ConnectorTool> tools;
}

/// The list could not be fetched. [message] is already a sentence for a person.
class ConnectorToolsUnavailable extends ConnectorToolsResult {
  const ConnectorToolsUnavailable(this.message);

  final String message;
}

/// Asks a connected connector what it can do.
///
/// **Two sources, because there are two kinds of connector.** A REST connector
/// carries its whole tool list inside the stored token (`rest_entry.tools`) —
/// the gateway wrote it there, and reading it is free and offline. An MCP
/// connector carries only a URL, so the only way to know is to ask its server;
/// `gmail` on this machine has an empty `rest_entry` and answers `tools/list`
/// with 23 tools (measured 2026-08-04). Showing the REST list for both would
/// leave every MCP connector — which is all of the Smithery directory — looking
/// permanently empty.
///
/// **No session handshake.** The transport allows a server to demand
/// `initialize` first and hand back an `Mcp-Session-Id`; Smithery's Gmail server
/// answers `tools/list` cold, with no session id in the reply. Rather than
/// guessing which servers need what, this sends `initialize` first and carries
/// any session id into the second call — the sequence a server that needs it
/// requires, and one an indifferent server ignores.
class ConnectorToolsService {
  const ConnectorToolsService(this._proxy);

  final McpProxy _proxy;

  Future<ConnectorToolsResult> toolsFor(ConnectorToken token) async {
    // Offline first: when the gateway already described the tools there is
    // nothing to ask anyone, and a network round trip would only add a spinner
    // and a way to fail.
    final rest = token.restEntry;
    if (rest != null && rest.tools.isNotEmpty) {
      return ConnectorToolsLoaded([
        for (final tool in rest.tools) _fromRest(tool),
      ]);
    }

    final entry = token.mcpEntry;
    if (entry == null) {
      return const ConnectorToolsUnavailable(
        "This connector hasn't told Grid what it can do yet.",
      );
    }

    // `initialize` is sent for its session id, not its answer: a server that
    // issues one rejects `tools/list` without it. A server that fails this step
    // outright is unreachable, and the sentence for that arrives below anyway.
    final handshake = await _proxy.forward(
      entry: entry,
      token: token,
      payload: const {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-03-26',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'grid', 'version': '1'},
        },
      },
    );

    final listed = await _proxy.forward(
      entry: entry,
      token: token,
      sessionId: handshake.sessionId,
      payload: const {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': <String, Object?>{},
      },
    );

    // The proxy turns transport failures into a JSON-RPC error object, so one
    // branch covers both that and a provider that genuinely refused.
    final error = listed.body['error'];
    if (error is Map) {
      final message = error['message'];
      return ConnectorToolsUnavailable(
        message is String && message.isNotEmpty
            ? message
            : "Couldn't ask this connector what it can do.",
      );
    }

    final result = listed.body['result'];
    final raw = result is Map ? result['tools'] : null;
    if (raw is! List) {
      return const ConnectorToolsUnavailable(
        "This connector replied in a way Grid couldn't read.",
      );
    }

    return ConnectorToolsLoaded([for (final item in raw) ?_fromMcp(item)]);
  }

  ConnectorTool _fromRest(RestTool tool) => ConnectorTool(
    name: tool.name,
    label: humanizeToolName(tool.name),
    description: humanizeDescription(tool.description),
  );

  ConnectorTool? _fromMcp(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    final description = raw['description'];
    return ConnectorTool(
      name: name,
      label: humanizeToolName(name),
      description: humanizeDescription(
        description is String ? description : '',
      ),
    );
  }
}

/// `fetch_message_by_thread_id` → `Fetch message by thread id`.
///
/// Tool names are identifiers written for a model: `snake_case` on the servers
/// measured here, `camelCase` elsewhere in the directory. Both are handled,
/// because a list of twenty raw identifiers is the thing that makes this panel
/// read as a debug view rather than an answer to "what can I do with this".
///
/// Deliberately conservative — it re-spaces and capitalises, and invents
/// nothing. A dictionary that turned `id` into `ID` would also have to know
/// about `url`, `api`, `cc`, and every vendor's abbreviations, and would be
/// wrong for the first one it had not been taught.
String humanizeToolName(String name) {
  final spaced = name
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      // A boundary inside `camelCase`, and the one in `HTTPResponse` — the
      // second needs the lookahead or every capital in an acronym gets split.
      .replaceAllMapped(
        RegExp(r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])'),
        (_) => ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (spaced.isEmpty) return name;
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// The provider's description, trimmed to something worth reading.
///
/// These are written for a model and it shows: Gmail's `add_label_to_email`
/// opens `"Adds and/or removes specified gmail labels for a message; ensure
/// \`message id\` exists"` — a sentence whose second half is an instruction to
/// the caller, not information for the user.
///
/// So this takes the first sentence and stops. Backticks go because they are
/// markdown that nothing here renders, and the whole is collapsed to one line
/// because a two-line description in a list of twenty makes a wall.
String humanizeDescription(String raw) {
  var text = raw.replaceAll('`', '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '';

  // Cut at the first sentence end. The lookbehind is what makes this safe on
  // real descriptions: measured against Gmail's 23 tools, a plain `[.;] +`
  // truncated `get_people` at "…or lists connections, e.g" — an abbreviation
  // ends in a period and a space exactly like a sentence does. Requiring two
  // letters before the stop keeps `e.g.`, `i.e.` and `v1.2` intact, at the cost
  // of running on through a genuine one-letter sentence ending, which does not
  // occur in this corpus.
  final stop = RegExp(r'(?<=[A-Za-z]{2})[.;] +(?=[A-Za-z])').firstMatch(text);
  if (stop != null) text = text.substring(0, stop.start);

  // A trailing period on a fragment that was cut, and none on one that was not,
  // makes a column of these look randomly punctuated. None of them get one.
  text = text.trim().replaceFirst(RegExp(r'[.;,:]+$'), '').trim();
  if (text.isEmpty) return '';
  // Lower-case openers are common here (`fetch_emails` starts "Fetches a list").
  return text[0].toUpperCase() + text.substring(1);
}

final connectorToolsServiceProvider = Provider<ConnectorToolsService>((ref) {
  final proxy = McpProxy();
  ref.onDispose(proxy.close);
  return ConnectorToolsService(proxy);
});

/// The tool list for one connector, fetched when its details dialog opens.
///
/// Keyed by connector id and `autoDispose`: the fetch is worth keeping while the
/// dialog is open — a rebuild must not refetch — and worth dropping when it
/// closes, so reopening after a reconnect asks again rather than showing the
/// tools of a connection that has since changed.
///
/// The token is passed in rather than read from the store: the dialog is opened
/// with a [Connector] that already carries it, and a second read would be a
/// second source of truth for the same fact.
final connectorToolsProvider = FutureProvider.autoDispose
    .family<ConnectorToolsResult, ConnectorToolsRequest>((ref, request) async {
      return ref.read(connectorToolsServiceProvider).toolsFor(request.token);
    });

/// The family key: a connector's id paired with the token to ask with.
///
/// The id is in the key — not just the token — so two connectors never share a
/// cache entry, and equality is by id plus the fields that would change the
/// answer, so a token refresh that only moves `expiresAt` does not refetch.
class ConnectorToolsRequest {
  const ConnectorToolsRequest({required this.connectorId, required this.token});

  final String connectorId;
  final ConnectorToken token;

  @override
  bool operator ==(Object other) =>
      other is ConnectorToolsRequest &&
      other.connectorId == connectorId &&
      other.token.mcpEntry?.url == token.mcpEntry?.url &&
      other.token.accessToken == token.accessToken;

  @override
  int get hashCode =>
      Object.hash(connectorId, token.mcpEntry?.url, token.accessToken);
}
