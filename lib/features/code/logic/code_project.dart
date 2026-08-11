import 'wire.dart';

/// A repository the grid hosts, with its own members — what `grid project list`
/// returns one of per row.
///
/// Addressed by **id**, never by name: a name is unique per owner, so it was
/// never an address a second member could use, and a project created by name
/// silently hands you an empty one of your own.
class GridProject {
  const GridProject({required this.id, required this.name, this.role});

  final String id;

  /// What the person who created it called it. Shown everywhere; used to
  /// address nothing.
  final String name;

  /// This account's part in it — `owner` or `member`. Null when the relay
  /// didn't say, which is an older one rather than a project with no roles.
  final String? role;

  /// Whether this account owns the project. Only an owner may admit members.
  bool get isOwner => role == 'owner';

  static GridProject? fromJson(Map<String, dynamic> json) {
    final id = wireString(json, 'id');
    if (id == null) return null;
    return GridProject(
      id: id,
      // A project with no name is still usable — it is addressed by id — so it
      // is shown by its id rather than dropped from the list.
      name: wireString(json, 'name') ?? id,
      role: wireString(json, 'role'),
    );
  }

  /// The `{projects: [...]}` body of `grid project list --json`.
  ///
  /// A body with no `projects` key reads as none, which is what an account with
  /// no projects genuinely looks like. The caller checks the exit code first,
  /// so a failure never reaches here to be mistaken for an empty list.
  static List<GridProject> listFromJson(Map<String, dynamic> json) => [
    for (final entry in wireObjects(json, 'projects')) ?fromJson(entry),
  ];

  @override
  bool operator ==(Object other) =>
      other is GridProject &&
      other.id == id &&
      other.name == name &&
      other.role == role;

  @override
  int get hashCode => Object.hash(id, name, role);
}

/// One person in a project, as `grid project member list` reports them.
class ProjectMember {
  const ProjectMember({required this.memberKey, this.email, this.role});

  /// This person's id **in this grid** — `sha256(user_id)` truncated, so the
  /// same person has a different key in every grid. It is what `promote` and
  /// `member remove` both take, and copying one from another grid gives you a
  /// command aimed at a branch that does not exist.
  final String memberKey;

  /// Their address, when the relay knows it. Absent reads as "(unknown)"
  /// rather than as an empty row.
  final String? email;

  final String? role;

  bool get isOwner => role == 'owner';

  /// The branch this member's tasks are cut from and settle back onto.
  String get branch => 'wip/$memberKey';

  static ProjectMember? fromJson(Map<String, dynamic> json) {
    final key = wireString(json, 'member_key');
    if (key == null) return null;
    return ProjectMember(
      memberKey: key,
      email: wireString(json, 'email'),
      role: wireString(json, 'role'),
    );
  }

  static List<ProjectMember> listFromJson(Map<String, dynamic> json) => [
    for (final entry in wireObjects(json, 'members')) ?fromJson(entry),
  ];

  @override
  bool operator ==(Object other) =>
      other is ProjectMember &&
      other.memberKey == memberKey &&
      other.email == email &&
      other.role == role;

  @override
  int get hashCode => Object.hash(memberKey, email, role);
}
