import '../../../core/subscription_model.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// One row of the sidebar's target menu: a grid this account belongs to, or the
/// choice to answer off every grid.
///
/// A record rather than a class (§3): it is a label and the thing it stands
/// for, and nothing else. [network] null **is** the subscription row — the one
/// row that names no grid, because it is the choice not to use one.
typedef GridTarget = ({String label, NetworkCredential? network});

/// Whether [target] is the row that answers off the grid.
bool isSubscriptionTarget(GridTarget target) => target.network == null;

/// The rows the sidebar's target menu shows, in the order it shows them: the
/// subscription row first, then every grid this account is on.
///
/// **First and always** — the same order the reference app's own target menu
/// uses, and for the same reason: it is the one row that depends on nothing
/// this app had to fetch, so it must not be a line that appears once a list
/// lands. Everything under it comes from the session.
///
/// [offerSubscription] is `subscriptionModelIsOffered` and an installed
/// assistant — false in a shipped build, where the menu is grids and nothing
/// else.
///
/// Pure, so the ordering and the gate are pinned by a test rather than read off
/// a menu by hand.
List<GridTarget> gridTargets({
  required List<NetworkCredential> networks,
  required bool offerSubscription,
}) => [
  if (offerSubscription) (label: kSubscriptionModelLabel, network: null),
  for (final network in networks) (label: network.name, network: network),
];

/// What the pill at the rail's foot says it is pointed at.
///
/// The **grid**, always — the pill is the grid switcher, and the model pill in
/// the composer is where a chat says what answers it. Falls back to a word
/// rather than to an empty pill: a control with no label reads as a control
/// that is broken, and "No grid" is a state this app can genuinely be in
/// (see `needsGridChoice`).
String gridTargetPillLabel(NetworkCredential? selected) {
  final name = selected?.name.trim() ?? '';
  return name.isEmpty ? 'No grid' : name;
}
