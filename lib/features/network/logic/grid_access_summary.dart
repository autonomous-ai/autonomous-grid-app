import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// Why the signed-in user can enter a grid — the one thing a row in the
/// choose-a-grid list has to say beyond its name.
///
/// Deliberately one axis with no gaps. The list badge it replaces was "Owner"
/// *or* "Public" *or* nothing at all, which crossed two unrelated questions —
/// what you are on the grid, and who else can get in — so a public grid you
/// owned hid that it was open, and a private grid you merely joined said
/// nothing and left the reader inferring "private" from an empty space. These
/// three are mutually exclusive and every grid lands on exactly one, so a row
/// can never be silent about the fact the screen exists to expose.
enum GridAccessTag {
  /// Open to anyone signed in to Grid. First in the ladder because it is the
  /// one a person needs to notice: it is the only value that means strangers
  /// can be here, and that stays true whether or not they also own the grid.
  public('Public'),

  /// Private, and the user made it. Would otherwise read [invited], which is a
  /// plain untruth about a grid you created yourself.
  owner('Owner'),

  /// Private, and the user was let in.
  invited('Invited');

  const GridAccessTag(this.label);

  final String label;
}

/// The access rule behind a `network_type` wire value, or null when it is one
/// this app never offers.
///
/// Only [ManagedNetworkType]'s own three are creatable here. Others exist and
/// reach `credentials.toml` anyway — `permissioned-providers` is retired and
/// web-only, and a grid already on it keeps that value forever.
ManagedNetworkType? accessTypeFromWire(String wire) {
  final normalised = wire.trim().toLowerCase();
  for (final type in ManagedNetworkType.values) {
    if (type.wire == normalised) return type;
  }
  return null;
}

/// Which tag [network] wears in the list.
///
/// Openness is read through [NetworkCredential.isPublic], not by matching the
/// wire value against [ManagedNetworkType]: a retired type such as
/// `permissioned-providers` is absent from that enum but present in
/// [kPublicNetworkTypes], and it is a live value on real accounts. Deciding
/// this from the enum would quietly label those grids private — the direction
/// that costs a user their privacy, because it is the one that hides the fact
/// that strangers can read the grid they are about to enter.
GridAccessTag gridAccessTagFor(NetworkCredential network) {
  if (network.isPublic) return GridAccessTag.public;
  if (network.role == NetworkRole.admin) return GridAccessTag.owner;
  return GridAccessTag.invited;
}
