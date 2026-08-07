/// One branch the current work can be compared against.
///
/// Carries *where* it lives rather than leaving the screen to guess from the
/// name: a local branch called `feat/x` and a remote one called `origin/main`
/// both have a slash in them, and a repository whose remote isn't named
/// `origin` breaks every guess anyone would write. Git already knows the
/// answer — it lists the two under different refs — so this keeps it.
class BranchRef {
  const BranchRef({required this.name, required this.remote});

  /// What Git will resolve: `origin/main`, `feat/x`.
  final String name;

  /// True when it lives on a remote — what the team has, rather than what only
  /// this computer has.
  final bool remote;

  @override
  bool operator ==(Object other) =>
      other is BranchRef && other.name == name && other.remote == remote;

  @override
  int get hashCode => Object.hash(name, remote);
}
