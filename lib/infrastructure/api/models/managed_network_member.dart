/// What an invited person may do on a managed (hosted) grid.
///
/// Exactly the two the control plane accepts from an app (`_MANAGED_MEMBER_ROLES`).
/// The other two of its four roles are absent for different reasons, and both
/// would be a 400 here:
///
/// - `admin` — the owner is the only admin, and is a member implicitly.
/// - `provider` — retired. It could host a machine but not CALL the grid, which
///   on an open grid left such a member WORSE OFF than a stranger: the allowlist
///   row pinned them to provider scopes while any signed-in non-member was
///   handed a consumer's. Use [both].
///
/// They nest — [both] is [use] plus hosting — so the picker is a short list, not
/// a tree, and the wider one is the default.
enum ManagedMemberRole {
  use('consumer', 'Use models', 'Use the grid\u2019s models.'),
  both(
    'both',
    'Use + run models',
    'Use the models, and run one of their own '
        'machines for the grid.',
  );

  const ManagedMemberRole(this.wire, this.label, this.description);

  /// Value sent in the `roles` array of the add-member request body.
  final String wire;

  /// Short name for the picker beside the email field.
  ///
  /// **Not "share".** [both] read "Can use and share", inside a dialog titled
  /// *Share* whose top half hands out access — so the one word had to mean two
  /// opposite things on one screen, and the reading a person lands on is the
  /// wrong one: that this grants them the right to invite others. "Run" is the
  /// app's own verb for putting a machine on a grid (the grid-power pill, and
  /// every [ManagedNetworkType] sentence), and it cannot be confused with
  /// handing out access.
  ///
  /// Kept SHORTER than the string it replaced (16 chars vs 17): the picker's
  /// width was measured against the old longest label, and the menu opens at
  /// the field's width, so a longer one would ellipsize in both.
  final String label;

  /// One line under the picker saying what the person will be able to do.
  final String description;

  /// The widest grant, and what every invite used to send before there was a
  /// picker. Guessing narrower would silently withhold something the inviter
  /// meant to give; they can always narrow it deliberately.
  static const ManagedMemberRole fallback = ManagedMemberRole.both;
}

/// The roles [viewerRoles] may hand out — never more than the inviter holds.
///
/// The control plane enforces this too (403 `role_above_caller`); the app filters
/// so the choice is never offered rather than refused after the fact. A member
/// who can only USE the grid must not be able to invite someone who can HOST on
/// it — a capability the inviter never had.
///
/// `admin` and `both` both carry hosting, so either may grant either role;
/// anything else may grant [ManagedMemberRole.use] alone. An unreadable role set
/// falls to the narrowest, which is the safe direction.
List<ManagedMemberRole> invitableRolesFor(List<String> viewerRoles) {
  final roles = viewerRoles.map((r) => r.toLowerCase()).toSet();
  if (roles.contains('admin') || roles.contains('both')) {
    return ManagedMemberRole.values;
  }
  return const [ManagedMemberRole.use];
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
