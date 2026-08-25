import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models/grid_invitation.dart';
import 'models/managed_network.dart';
import 'models/managed_network_member.dart';

/// A failed managed-network call. [message] is the friendly, plain-language line
/// for the UI; [statusCode] and [body] carry the raw detail the Debug tab shows,
/// so an opaque failure (e.g. a 502) isn't just "Error 502." with nothing to go on.
class ManagedNetworkError {
  const ManagedNetworkError(this.message, {this.statusCode, this.body});

  /// User-facing reason, shown in the create dialog.
  final String message;

  /// HTTP status when the server answered; null for transport failures
  /// (timeout, unreachable host) where there was no response.
  final int? statusCode;

  /// Raw response body when the server sent one — often the only clue for a
  /// gateway error. Null/empty for transport failures.
  final String? body;

  /// The Debug-tab line: the friendly message plus any raw server body (clipped),
  /// so the log shows exactly what came back rather than a one-word code.
  String get debugDetail {
    final raw = body?.trim();
    if (raw == null || raw.isEmpty || raw == message) return message;
    final clipped = raw.length > 1000 ? '${raw.substring(0, 1000)}…' : raw;
    return '$message\n$clipped';
  }
}

/// Control-plane call to `POST /v1/grid/managed-networks`, authenticated with
/// the GridSession bearer (the `session_token` from `~/.grid/credentials.toml`).
///
/// A thin [HttpClient] wrapper that returns `(network, null)` on success or
/// `(null, error)` on failure — it never throws.
class ManagedNetworkClient {
  const ManagedNetworkClient._();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/grid/managed-networks';

  /// The generic network path. Editing a grid (`PATCH …/networks/{id}`) is
  /// served here, not under `managed-networks` — the control plane keeps the
  /// managed routes for provisioning (create / start / stop / members).
  static const String _networksPath = 'v1/grid/networks';

  static Future<(ManagedNetwork?, ManagedNetworkError?)> create({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(endpoint(apiUrl));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode(createBody(name, type))));

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ManagedNetworkError(
            _errorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (
        ManagedNetwork.fromJson(jsonDecode(body) as Map<String, dynamic>),
        null,
      );
    } on TimeoutException {
      return (
        null,
        const ManagedNetworkError(
          "The server didn't respond in time. Try again.",
        ),
      );
    } on SocketException catch (e) {
      return (
        null,
        ManagedNetworkError(
          "Couldn't reach the Grid control plane: ${e.message}",
        ),
      );
    } on Object catch (e) {
      return (null, ManagedNetworkError("Couldn't create the network: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// Lists active members of [networkId] via
  /// `GET /v1/grid/managed-networks/{network_id}/members`. Owner-only on the
  /// server (403 otherwise). Tolerates either a `{"members": [...]}` envelope or
  /// a bare list, since the endpoint is loosely typed.
  static Future<(List<ManagedNetworkMember>?, String?)> listMembers({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(membersEndpoint(apiUrl, networkId));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _memberErrorFor(response.statusCode, body));
      }
      final decoded = jsonDecode(body);
      final rawList = decoded is Map ? decoded['members'] : decoded;
      if (rawList is! List) {
        return (null, 'The server returned an unexpected members response.');
      }
      final members = rawList
          .whereType<Map>()
          .map((m) => ManagedNetworkMember.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false);
      return (members, null);
    } on TimeoutException {
      return (null, "The server didn't respond in time. Try again.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't load members: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Adds (invites) a member to [networkId] via
  /// `POST /v1/grid/managed-networks/{network_id}/members`. [roles] are wire
  /// values from [ManagedMemberRole]; `admin` is rejected server-side.
  static Future<(ManagedNetworkMember?, String?)> addMember({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required String email,
    required List<String> roles,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(membersEndpoint(apiUrl, networkId));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode(addMemberBody(email, roles))));

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _memberErrorFor(response.statusCode, body));
      }
      return (
        ManagedNetworkMember.fromJson(jsonDecode(body) as Map<String, dynamic>),
        null,
      );
    } on TimeoutException {
      return (null, "The server didn't respond in time. Try again.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't add the member: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// The email domain this account may gate a grid by, from `GET /v1/grid/me` —
  /// or null when it may not.
  ///
  /// Asked of the server rather than worked out from the address here: the list
  /// of public providers that cannot gate a grid is a control-plane env var, and
  /// a copy of it in the app is one that drifts — the app would keep offering
  /// "my domain" to a domain the API has started refusing, or hide it from one
  /// it has started allowing.
  ///
  /// The DOMAIN rather than a yes/no, because the label has to name it: "Only
  /// acme.dev" is the rule, while "My domain" is a pronoun the owner has to
  /// resolve themselves — and on the grid where it matters they are choosing
  /// exactly which domain gets in.
  ///
  /// Returns `(null, error)` on failure, and the caller treats that as "don't
  /// offer it": the create form must not present a choice the API may reject.
  static Future<(String?, String?)> canRestrictToDomain({
    required String apiUrl,
    required String sessionToken,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(_url(apiUrl, 'v1/grid/me'));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, 'HTTP ${response.statusCode}');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final user = json['user'];
      if (user is! Map) return (null, null);
      // Absent on a control plane too old to answer — read as "no", so an old
      // server hides the option instead of offering one it will refuse.
      if (user['can_restrict_to_domain'] != true) return (null, null);
      final domain = user['email_domain'];
      return (domain is String && domain.isNotEmpty ? domain : null, null);
    } on TimeoutException {
      return (null, "The server didn't respond in time.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't read your account: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Invitations the signed-in account has not acknowledged, via
  /// `GET /v1/grid/me/memberships`.
  ///
  /// Polled, so its timeouts are short: a slow answer here is worth abandoning
  /// and retrying on the next tick rather than holding a socket open across it.
  static Future<(List<GridInvitation>?, String?)> listInvitations({
    required String apiUrl,
    required String sessionToken,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(invitationsEndpoint(apiUrl));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _errorFor(response.statusCode, body));
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final rows = json['memberships'];
      // An older control plane has no such route and answers something else
      // entirely; an empty list is the honest reading of "it told us nothing".
      if (rows is! List) return (const <GridInvitation>[], null);
      return (
        [
          for (final row in rows)
            if (row is Map<String, dynamic>) GridInvitation.fromJson(row),
        ],
        null,
      );
    } on TimeoutException {
      return (null, "The server didn't respond in time.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't read your invitations: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Acknowledges [networkIds] via `POST /v1/grid/me/memberships/seen`. Returns
  /// how many were unread until this call.
  ///
  /// Always a list, including for "mark all as read" — the server has no
  /// "everything" flag on purpose, so that a request can only ever acknowledge
  /// what was on screen when the person tapped. An invitation that lands between
  /// the poll and the tap stays unread instead of being dismissed unseen.
  static Future<(int?, String?)> markInvitationsSeen({
    required String apiUrl,
    required String sessionToken,
    required List<String> networkIds,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(invitationsSeenEndpoint(apiUrl));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode({'network_ids': networkIds})));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _errorFor(response.statusCode, body));
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return ((json['seen'] as num?)?.toInt() ?? 0, null);
    } on TimeoutException {
      return (null, "The server didn't respond in time.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't mark your invitations as read: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Changes who can reach [networkId] via
  /// `POST /v1/grid/managed-networks/{network_id}/network-type`. Owner only.
  ///
  /// Slow on purpose: the control plane restarts the grid's server onto the new
  /// rule, so the grid is briefly unreachable and every access token in
  /// circulation is invalidated. The timeout is generous for that reason —
  /// giving up early would leave the app unsure whether the change landed.
  static Future<(bool, String?)> setNetworkType({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required ManagedNetworkType type,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(
        networkTypeEndpoint(apiUrl, networkId),
      );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode(networkTypeBody(type))));

      final response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (false, _networkTypeErrorFor(response.statusCode, body));
      }
      return (true, null);
    } on TimeoutException {
      return (
        false,
        "The server didn't answer in time. The grid may still be restarting — "
            'check its access rule again in a moment.',
      );
    } on SocketException catch (e) {
      return (false, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (false, "Couldn't change who can reach this grid: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Removes [email] from [networkId] via
  /// `DELETE /v1/grid/managed-networks/{network_id}/members/{email}`. Returns
  /// `(true, null)` on success.
  static Future<(bool, String?)> removeMember({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required String email,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.deleteUrl(
        memberEndpoint(apiUrl, networkId, email),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (false, _memberErrorFor(response.statusCode, body));
      }
      return (true, null);
    } on TimeoutException {
      return (false, "The server didn't respond in time. Try again.");
    } on SocketException catch (e) {
      return (false, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (false, "Couldn't remove the member: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Renames the grid [networkId] via `PATCH /v1/grid/networks/{network_id}`,
  /// sending only `name` so the grid's type and status are left untouched.
  /// Owner-only on the server (403 otherwise). Returns `(true, null)` on
  /// success.
  ///
  /// The grid's id never changes, so everything keyed by it (tokens, joined
  /// engines, the Base URL) keeps working — only the display name moves.
  ///
  /// TODO(BE): this endpoint accepts any `name` — unlike create, it applies no
  /// length/character rule and no duplicate check. The app validates with
  /// `gridNameError` first, but another client could still write a name that
  /// create would have rejected.
  static Future<(bool, ManagedNetworkError?)> rename({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required String name,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.patchUrl(renameEndpoint(apiUrl, networkId));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode(renameBody(name))));

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          false,
          ManagedNetworkError(
            _renameErrorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (true, null);
    } on TimeoutException {
      return (
        false,
        const ManagedNetworkError(
          "The server didn't respond in time. Try again.",
        ),
      );
    } on SocketException catch (e) {
      return (
        false,
        ManagedNetworkError(
          "Couldn't reach the Grid control plane: ${e.message}",
        ),
      );
    } on Object catch (e) {
      return (false, ManagedNetworkError("Couldn't rename the grid: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes the managed network [networkId] via
  /// `DELETE /v1/grid/managed-networks/{network_id}`. Owner-only on the server
  /// (403 otherwise). Returns `(true, null)` on success.
  static Future<(bool, ManagedNetworkError?)> delete({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.deleteUrl(
        networkEndpoint(apiUrl, networkId),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          false,
          ManagedNetworkError(
            _deleteErrorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (true, null);
    } on TimeoutException {
      return (
        false,
        const ManagedNetworkError(
          "The server didn't respond in time. Try again.",
        ),
      );
    } on SocketException catch (e) {
      return (
        false,
        ManagedNetworkError(
          "Couldn't reach the Grid control plane: ${e.message}",
        ),
      );
    } on Object catch (e) {
      return (false, ManagedNetworkError("Couldn't delete the grid: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// The full create-managed-network URL for [apiUrl] (which may or may not end
  /// in `/`). Public so callers can log the same URL the request hits.
  static Uri endpoint(String apiUrl) => _url(apiUrl, _path);

  /// The request bodies, public for the same reason the URLs are: a caller
  /// logging what it sent reads the payload from here rather than writing a
  /// second copy of it, which is a copy that drifts.
  static Map<String, dynamic> createBody(
    String name,
    ManagedNetworkType type,
  ) => {'name': name, 'network_type': type.wire};

  static Map<String, dynamic> addMemberBody(String email, List<String> roles) =>
      {'email': email, 'roles': roles};

  static Map<String, dynamic> networkTypeBody(ManagedNetworkType type) => {
    'network_type': type.wire,
  };

  /// The change-access-rule URL for [networkId].
  static Uri networkTypeEndpoint(String apiUrl, String networkId) =>
      _url(apiUrl, '$_path/$networkId/network-type');

  static Map<String, dynamic> renameBody(String name) => {'name': name};

  /// The rename (PATCH) URL for [networkId]. Public so callers can log the same
  /// URL the request hits.
  static Uri renameEndpoint(String apiUrl, String networkId) =>
      _url(apiUrl, '$_networksPath/$networkId');

  /// [path] resolved against the control-plane base [apiUrl], which may or may
  /// not end in `/`.
  static Uri _url(String apiUrl, String path) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$path');
  }

  /// Where invitations are listed. Public so callers can log the URL they hit.
  static Uri invitationsEndpoint(String apiUrl) =>
      _url(apiUrl, 'v1/grid/me/memberships');

  /// Where invitations are acknowledged.
  static Uri invitationsSeenEndpoint(String apiUrl) =>
      _url(apiUrl, 'v1/grid/me/memberships/seen');

  /// The single-network URL for [networkId] (GET/DELETE). Public so callers can
  /// log the same URL the request hits.
  static Uri networkEndpoint(String apiUrl, String networkId) =>
      Uri.parse('${endpoint(apiUrl)}/$networkId');

  /// The members collection URL for [networkId]. Public so callers can log the
  /// same URL the request hits.
  static Uri membersEndpoint(String apiUrl, String networkId) =>
      Uri.parse('${networkEndpoint(apiUrl, networkId)}/members');

  /// The single-member URL for a DELETE. [email] is path-encoded.
  static Uri memberEndpoint(String apiUrl, String networkId, String email) =>
      Uri.parse(
        '${membersEndpoint(apiUrl, networkId)}'
        '/${Uri.encodeComponent(email)}',
      );

  /// Turns a non-2xx response into a user-facing message, preferring the
  /// server's own `detail`/`message`, with friendlier text for known codes.
  static String _errorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'Your session has expired. Sign in again.',
      402 => detail ?? "You've reached your plan's network limit.",
      409 => detail ?? 'You already own a network with this name.',
      422 => detail ?? 'Invalid name or network type.',
      502 || 503 => detail ?? 'The grid service is busy right now. Try again.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Delete-endpoint variant of [_errorFor] — owner-only, and the grid may
  /// already be gone (404) on a double-delete.
  static String _deleteErrorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'Your session has expired. Sign in again.',
      403 => detail ?? 'Only the grid owner can delete this grid.',
      404 => detail ?? 'This grid is no longer available.',
      409 => detail ?? "This grid can't be deleted right now.",
      502 || 503 => detail ?? 'The grid service is busy right now. Try again.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Rename-endpoint variant of [_errorFor] — owner-only, and the name may be
  /// one the server won't take (a duplicate, or bad characters).
  static String _renameErrorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      400 || 422 => detail ?? 'That name is not allowed. Try another.',
      401 => 'Your session has expired. Sign in again.',
      403 => detail ?? 'Only the grid owner can rename this grid.',
      404 => detail ?? 'This grid is no longer available.',
      409 => detail ?? 'You already have a grid with this name.',
      502 || 503 => detail ?? 'The grid service is busy right now. Try again.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Member-endpoint variant of [_errorFor] — same `detail`-first strategy with
  /// messages tuned to the add/remove/list flow (owner-only, seat caps, etc.).
  static String _memberErrorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      400 => detail ?? 'Invalid email or role for this grid.',
      401 => 'Your session has expired. Sign in again.',
      402 => detail ?? "You've reached your plan's member limit.",
      403 => detail ?? 'Only the grid owner can manage members.',
      404 => detail ?? 'This grid is no longer available.',
      422 => detail ?? 'Invalid email or role.',
      502 => detail ?? 'The grid service is busy right now. Try again.',
      503 => detail ?? 'Member management is unavailable right now.',
      _ => detail ?? 'Error $status.',
    };
  }

  static String _networkTypeErrorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      400 => detail ?? "This grid can't use that rule.",
      401 => 'Your session has expired. Sign in again.',
      403 => detail ?? 'Only the grid owner can change who can reach it.',
      404 => detail ?? 'This grid is no longer available.',
      422 => detail ?? 'That access rule is not available.',
      // The one failure a person must react to differently: the grid is either
      // back the way it was, or it is stopped and needs starting. `_detailOf`
      // already returns the server's sentence, which says which.
      502 => detail ?? 'The change failed. Check whether the grid is running.',
      503 => detail ?? 'Grid management is unavailable right now.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Pulls a human message out of a FastAPI error body
  /// (`{"detail": ...}`), tolerating plain-string or validation-list shapes.
  static String? _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final detail = decoded['detail'] ?? decoded['message'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] != null) return '${first['msg']}';
      }
    } on Object {
      // Non-JSON body — let the caller fall back to a generic message.
    }
    return null;
  }
}
