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
  use(
    'consumer',
    'Use models',
    'They can use every model on this grid, but not run one for it.',
    'Send work to the models on this grid.',
  ),
  both(
    'both',
    'Share a computer',
    'They can use every model on this grid, and run one of their own '
        'computers for it.',
    'That, plus run a model on their own computer for this grid.',
  );

  const ManagedMemberRole(this.wire, this.label, this.description, this.detail);

  /// Value sent in the `roles` array of the add-member request body.
  final String wire;

  /// What to call this grant, in the words for what it lets someone DO.
  ///
  /// Google Docs can get away with one-word nouns because everyone already
  /// knows what a viewer and an editor are. Grid's two roles are not folk
  /// knowledge — "User" and "Host" both passed for a while and neither said
  /// which one could put a machine on the grid — so the label names the action
  /// instead, and "a computer" is what makes the second one land: it is a
  /// *machine* being shared, not access being handed out.
  ///
  /// "Share" here does not collide with the dialog's own title: sharing a
  /// **computer** cannot be misread as sharing the grid, and it is the phrase
  /// the app already uses everywhere else for this ("Sharing this computer on
  /// your grid", "Share a model from this computer").
  ///
  /// The two labels are **parallel verbs, not a sum**. "Use + share a computer"
  /// spelled the nesting out in the label and read as a formula: no label
  /// anywhere else in the app uses `+` for "and" (the only ones that carry it
  /// are a count, "+3 more", and a shortcut, "⌘1"). The nesting moves to
  /// [detail], where "That, plus…" says it in words, under the row it refers
  /// to.
  ///
  /// **This overrides "Use + run models"**, which reached main first (ed226253)
  /// on the argument that *share* cannot appear in a dialog titled Share
  /// without being read as "may invite others". The argument is right about the
  /// bare verb and wrong about this phrase: what is shared here is **a
  /// computer**, which is not a thing anyone can be invited to, and it is the
  /// object the app already attaches the verb to everywhere else ("Sharing this
  /// computer on your grid"). Chosen by the product owner with both labels on
  /// screen, and the `+` in the alternative was the half he rejected outright.
  final String label;

  /// One line under the invite row saying what the person will be able to do.
  ///
  /// Written about *them*, not about the reader, because it is read while
  /// inviting someone else: "They can use every model on this grid…".
  final String description;

  /// The line under this role **inside the menu**, where the row is narrow and
  /// the reader is mid-decision.
  ///
  /// Shorter than [description] and phrased as the action rather than as a
  /// sentence about a person, because in the menu the two roles are read
  /// against each other — [both]'s "That, plus…" only makes sense stacked under
  /// [use]'s line, which is exactly how the menu shows them.
  ///
  /// A menu row that carries an explanation is a deliberate exception to the
  /// label-only rule the access menu otherwise follows (see [AccessMenuRow]):
  /// "Invite only" needs no gloss, "Share a computer" does — on its own it
  /// does not say that the person may use the grid's models too.
  final String detail;

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

  /// The grant this member holds, or null when the control plane names one the
  /// app doesn't offer — the owner's `admin`, or the retired `provider`.
  ///
  /// The people list prints this in every row: the roster already carries it,
  /// and a share sheet that can't say who may run a model for the grid is
  /// hiding the one fact the invite picker made a decision about.
  ///
  /// `both` wins over `consumer` when a row somehow carries both: it is the
  /// wider grant, and reporting the narrower one would understate what the
  /// person can do.
  ManagedMemberRole? get grantedRole {
    final held = roles.map((role) => role.toLowerCase()).toSet();
    if (held.contains(ManagedMemberRole.both.wire)) {
      return ManagedMemberRole.both;
    }
    if (held.contains(ManagedMemberRole.use.wire)) return ManagedMemberRole.use;
    return null;
  }

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
