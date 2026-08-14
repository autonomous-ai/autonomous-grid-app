/// Which grid a relay URL names, which grid a relay token was minted for, and
/// whether the two agree.
///
/// A grid's identity lives in the **path** of its relay URL —
/// `https://grid.autonomous.ai/grid-3378218621364f16/relay/v1` — never in the
/// host, which every grid on the same deployment shares. The token minted for
/// that grid carries the same id as its JWT audience (`aud: grid:<network_id>`)
/// and the relay enforces it: a token from one grid sent to another grid's path
/// comes back
/// `HTTP 401: {"detail":"Invalid Grid token: Audience doesn't match"}`.
///
/// So every identity the app hands a client app — the `name` of a provider entry
/// in its config, and through it the key a credential pool is filed under — has
/// to carry the grid id. Naming by host alone collapses all of a user's grids
/// into one identity, and that is how grid A's key ends up paired with grid B's
/// URL: the client app can no longer tell them apart.
library;

import 'dart:convert';

/// The grid id in a relay base URL (`…/<grid-id>/relay/v1`), or null when the
/// URL names no grid — a LAN relay is reached at `http://host:port/relay/v1`
/// with nothing in front of it, and a hand-typed endpoint may be anything.
String? gridIdFromRelayBase(String base) {
  final uri = Uri.tryParse(base);
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 3) return null;
  if (segments[segments.length - 2] != 'relay') return null;
  final id = segments[segments.length - 3];
  return id.isEmpty ? null : id;
}

/// Whether [url] is some grid's relay base — the shape the app writes into a
/// client app's config. Used to recognise the entries and pooled credentials
/// *this app* left behind for a grid, so switching grids can clear them out
/// without touching a provider the user configured themselves.
bool isGridRelayBase(String url) => gridIdFromRelayBase(url) != null;

/// Two relay base URLs naming the same endpoint, trailing slash and all.
bool sameRelayBase(String a, String b) =>
    a.trim().replaceFirst(RegExp(r'/+$'), '') ==
    b.trim().replaceFirst(RegExp(r'/+$'), '');

/// The grid id a relay token was minted for, read from the JWT's `aud` claim
/// (`grid:<network_id>`), or null when [key] isn't a decodable grid JWT.
///
/// Deliberately signature-blind: this is not an authorisation check — only the
/// relay can make one — it is how the app catches itself about to hand a client
/// app a credential for the wrong grid.
String? gridIdFromRelayToken(String key) {
  final parts = key.split('.');
  if (parts.length != 3) return null;
  final Object? claims;
  try {
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    payload = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
    claims = jsonDecode(utf8.decode(base64.decode(payload)));
  } on Object {
    return null;
  }
  if (claims is! Map) return null;
  // `aud` is a string in every token the control plane mints, but the JWT spec
  // allows an array — read both rather than silently failing open on one.
  final aud = claims['aud'];
  final value = aud is List
      ? aud.whereType<String>().firstOrNull
      : (aud is String ? aud : null);
  if (value == null || !value.startsWith('grid:')) return null;
  final id = value.substring('grid:'.length);
  return id.isEmpty ? null : id;
}

/// Why [key] must not be written as the credential for [base], or null when the
/// pair agrees — or when there isn't enough in either to tell (a LAN relay, an
/// API-engine key that is no JWT at all). Fails open on purpose: this guard
/// exists to stop a *known* mismatch reaching disk, not to gate connections the
/// app can't reason about.
String? relayCredentialMismatch({required String base, required String key}) {
  final wanted = gridIdFromRelayBase(base);
  final carried = gridIdFromRelayToken(key);
  if (wanted == null || carried == null || wanted == carried) return null;
  return 'the key belongs to grid $carried, but the endpoint is grid $wanted';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
