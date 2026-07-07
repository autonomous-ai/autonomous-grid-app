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
  });

  final String email;
  final List<String> roles;

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

  factory ManagedNetworkMember.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];
    return ManagedNetworkMember(
      email: (json['email'] ?? '') as String,
      roles: rawRoles is List
          ? rawRoles.map((e) => e.toString()).toList()
          : const [],
      status: json['status'] as String?,
      paymentStatus: json['payment_status'] as String?,
    );
  }
}
