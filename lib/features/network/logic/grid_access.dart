/// Who can reach a grid, in the three shapes the control plane actually ships.
///
/// Derived from `network_type`, whose **wire names read backwards** — the same
/// trap `NetworkCredential.isPublic` carries a warning about, so this maps by
/// the same substrings rather than by equality:
///
/// - `permissioned-public`    → [restricted]: both providers and consumers are
///   whitelisted, so only invited people get in. The word "public" in the wire
///   value is the one that lies.
/// - `private-domain`         → [domain]: an organisation's own grid, named
///   for that organisation's email domain. Observed live in
///   `~/.grid/credentials.toml`; neither this repo nor the CLI names the value
///   anywhere else.
///
///   **It is invite-only, exactly like [restricted].** The domain says *whose*
///   grid it is, not who may walk into it — anyone at the domain still has to
///   be added to the member list. This was first read the other way, from the
///   name and from an analogy with Google Workspace rather than from anything
///   the product does, and the dialog told users their grid was open to their
///   whole company when it wasn't. The evidence was in the repo the whole
///   time: `NetworkCredential.isPublic` keys off `providers`, so this type has
///   always resolved to Private.
/// - `permissioned-providers` → [anyone]: only providers are whitelisted, so
///   anyone signed in can consume.
///
/// Matched on substrings, and `domain` is checked first: an unknown future
/// variant lands on the *narrowest* reading rather than silently opening a grid
/// up. Guessing wrong here would tell someone their grid is invite-only while
/// strangers use it.
enum GridAccess { restricted, domain, anyone }

/// [GridAccess] for a raw `network_type`.
GridAccess gridAccessFor(String networkType) {
  final type = networkType.toLowerCase();
  if (type.contains('domain')) return GridAccess.domain;
  if (type.contains('providers')) return GridAccess.anyone;
  return GridAccess.restricted;
}

/// A light client-side sanity check — the server is the real validator, this
/// just spares an obvious round-trip.
bool looksLikeEmail(String value) {
  final at = value.indexOf('@');
  return at > 0 && at < value.length - 1 && !value.contains(' ');
}
