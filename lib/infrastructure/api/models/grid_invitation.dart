import 'managed_network_member.dart';

/// One grid somebody added you to, as `GET /v1/grid/me/memberships` reports it.
///
/// Narrower than "a grid you can reach", and the difference is the whole reason
/// this exists: a grid you can use because it is open, or because it admits your
/// email domain, was not an invitation — nobody chose you, so there is no person
/// and no moment to name. The control plane answers from the member list itself,
/// so every row here has a real [addedBy] and [addedAt].
class GridInvitation {
  const GridInvitation({
    required this.networkId,
    required this.name,
    required this.networkType,
    required this.ownerEmail,
    required this.addedBy,
    required this.addedAt,
    required this.roles,
    required this.seen,
  });

  final String networkId;
  final String name;
  final String networkType;
  final String ownerEmail;

  /// The email of the person who added you. Not the owner's — an admin can
  /// invite on a grid they do not own, and saying "owner" there would name the
  /// wrong person.
  final String addedBy;

  /// When the membership row was first written, in epoch **seconds**.
  ///
  /// Seconds, not milliseconds: the control plane's `now_ts()` is seconds
  /// throughout, and reading it as ms puts every invitation in January 1970.
  final int addedAt;

  final List<String> roles;

  /// Whether this invitation has been acknowledged. The default listing returns
  /// only unseen ones, so this is `false` on everything the badge counts; it is
  /// carried anyway because `?unseen=false` returns the whole history.
  final bool seen;

  /// What the invited person may do here, or null for a role set this app has no
  /// name for — a legacy `provider` row, or something a newer server invented.
  /// Callers must handle null rather than guess: naming a grant wrongly is worse
  /// than not naming it.
  ManagedMemberRole? get role {
    final wire = roles.map((r) => r.toLowerCase()).toSet();
    if (wire.contains('admin') || wire.contains('both')) {
      return ManagedMemberRole.both;
    }
    if (wire.contains('consumer')) return ManagedMemberRole.use;
    return null;
  }

  factory GridInvitation.fromJson(Map<String, dynamic> json) {
    return GridInvitation(
      networkId: (json['network_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      networkType: (json['network_type'] ?? '') as String,
      ownerEmail: (json['owner_email'] ?? '') as String,
      addedBy: (json['added_by'] ?? '') as String,
      addedAt: (json['added_at'] as num?)?.toInt() ?? 0,
      roles: [
        for (final role in (json['roles'] as List? ?? const []))
          if (role is String) role,
      ],
      // Absent on a control plane that predates the flag. Reading that as
      // "unseen" is the safe direction — the invitation shows up once and the
      // person can dismiss it — where reading it as "seen" would hide an
      // invitation the server is still calling new.
      seen: json['seen'] == true,
    );
  }
}
