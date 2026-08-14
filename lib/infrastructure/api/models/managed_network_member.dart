/// The role a member can be granted on a managed (hosted) grid. Mirrors the
/// `roles` enum the control plane accepts in `ManagedMemberRequest` — `admin`
/// is intentionally absent because the API rejects it (the owner is the only
/// admin, and is a member implicitly).
enum ManagedMemberRole {
  consumer('consumer'),
  provider('provider'),
  both('both');

  const ManagedMemberRole(this.wire);

  /// Value sent in the `roles` array of the add-member request body.
  final String wire;
}

/// One member of a managed grid, as returned by
/// `GET /v1/grid/managed-networks/{network_id}/members`. The response is loosely
/// typed server-side, so every field beyond [email] is treated as optional.
class ManagedNetworkMember {
  const ManagedNetworkMember({
    required this.email,
    required this.roles,
    this.status,
    this.paymentStatus,
    this.source,
  });

  final String email;
  final List<String> roles;

  /// Where the membership comes from: `allowlist` — someone added them, so they
  /// can be removed — or `domain`, meaning the grid admits every account on its
  /// email domain and this person is on it by their address alone. Null from a
  /// control plane too old to say.
  final String? source;

  /// `active` / `inactive` — only active members are listed, but kept so the UI
  /// can render a badge without guessing.
  final String? status;

  /// Plan/billing state for the seat (e.g. `paid`, `trialing`), when present.
  final String? paymentStatus;

  /// Whether this member is the grid owner. The control plane marks the owner
  /// with the `admin` role (same vocabulary as the credential's roles claim),
  /// and the owner can never be removed — so this drives the "Owner" badge and
  /// hides the remove button. Derived from the member itself, never from who is
  /// currently viewing the list.
  bool get isOwner => roles.contains('admin');

  /// Whether this person is on the grid because their email is on its domain,
  /// rather than because anyone added them. Removing such a member takes nothing
  /// away — they'd still sign in and be admitted — so the UI offers no Remove.
  bool get isDomainMember => source == 'domain';

  factory ManagedNetworkMember.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];
    return ManagedNetworkMember(
      email: (json['email'] ?? '') as String,
      roles: rawRoles is List
          ? rawRoles.map((e) => e.toString()).toList()
          : const [],
      status: json['status'] as String?,
      paymentStatus: json['payment_status'] as String?,
      source: json['source'] as String?,
    );
  }
}
