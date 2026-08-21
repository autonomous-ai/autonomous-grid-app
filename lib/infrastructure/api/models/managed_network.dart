/// Every `network_type` the control plane has used for the **open** grid — the
/// one anyone signed in can consume from.
///
/// A set rather than one string, because the wire value was renamed on
/// 2026-08-20 (`permissioned-providers` → `permissionless`) and a grid created
/// before that still reports the old spelling. Both are the same product thing.
///
/// Read by exact match, never by substring. The old spelling happened to
/// contain the word "providers" and two readers keyed off *that*; when the
/// rename dropped the word, both of them silently flipped the grid to private —
/// see [kPublicNetworkTypes]'s callers for what that cost.
///
/// Deliberately NOT derived from [ManagedNetworkType]: that enum lists the rules
/// an owner may CHOOSE, and `permissioned-providers` is retired — creatable only
/// by the web front end, never offered here. A grid already on it still has to
/// read as open, so the two lists answer different questions and must stay apart.
const Set<String> kPublicNetworkTypes = {
  'permissionless',
  'permissioned-providers',
};

/// Who can reach a grid — the three access rules the control plane offers, both
/// when creating a grid (`POST /managed-networks`) and when its owner changes
/// one afterwards (`POST /managed-networks/{id}/network-type`).
///
/// **The wire names read backwards and the enum names now say so.**
/// `permissioned-public` is the PRIVATE one — the word "public" in it refers to
/// the signaling server being publicly reachable, not to who may use the grid.
/// The constants are named for what they MEAN, so a reader never has to hold
/// that inversion in their head; trust the name and [wire], in that order.
///
/// [domain] is only offered when the signed-in account can actually gate by its
/// email domain — `can_restrict_to_domain` on `GET /v1/grid/me`, false for a
/// public provider like gmail.com, where "only my domain" would mean *all of
/// Gmail*. That list lives in a server env var; the app never keeps a copy,
/// because a second copy is one that drifts.
enum ManagedNetworkType {
  restricted(
    'permissioned-public',
    'Invite only',
    'Only people you invite can use this grid, or run a model for it.',
  ),
  domain(
    'domain-restricted',
    'My domain',
    'Anyone with an email on your domain can use this grid, or run a model '
        'for it — as well as the people you invite.',
  ),
  anyone(
    'permissionless',
    'Anyone',
    'Anyone signed in to Grid can use this grid, or run a model for it.',
  );

  const ManagedNetworkType(this.wire, this.label, this.description);

  /// Value sent as `network_type`.
  final String wire;

  /// Short name for the segmented picker.
  final String label;

  /// The plain-language explanation under the picker — who gets to *use* the
  /// grid, and who gets to *supply* it.
  ///
  /// It read "Whitelist providers only — consumers can join freely", which is
  /// the wire contract written out: three words a user has never met (§5), for
  /// the one choice on this form they cannot undo by clicking around.
  ///
  /// The sentences are deliberately parallel and differ only where the rules
  /// differ, so a person comparing them sees the actual decision rather than
  /// three paragraphs to read.
  ///
  /// **"Share a computer" became "run a model for it"** after a user read the
  /// first one as inviting people — which, inside a dialog titled *Share* whose
  /// top half does exactly that, is the obvious reading. "Run a model" is the
  /// app's own phrase from the grid-power pill, and it cannot be confused with
  /// handing out access.
  ///
  /// **[domain] gained a clause and lost a meaning on 2026-08-21.** It read
  /// "including anyone invited earlier on a different one", because the server
  /// checked the domain BEFORE the invite list and switching to this rule cut
  /// invited outsiders off. That was the wrong reading of what an owner asks
  /// for: they are choosing how colleagues get in without an invite each, not
  /// revoking the people they invited on purpose. The domain now ADMITS rather
  /// than excludes, so the clause says "as well as" — the opposite of what the
  /// same sentence used to warn about. Removing someone from the list is still
  /// what takes their access away.
  final String description;

  /// The API default when `network_type` is omitted, and the safe pick for a
  /// new grid: the narrowest of the three. Opening a grid up later is one
  /// click; the people who used it in the meantime cannot be un-let-in.
  static const ManagedNetworkType fallback = ManagedNetworkType.restricted;

  /// The rule a raw `network_type` names, or null for one this picker does not
  /// offer — `permissioned-providers` (what the web's "Public" creates) and
  /// `private-domain` (auto-provisioned per email domain) are both real and
  /// both absent here, so callers must handle null rather than assume.
  static ManagedNetworkType? fromWire(String? value) {
    final wire = (value ?? '').toLowerCase();
    for (final type in ManagedNetworkType.values) {
      if (type.wire == wire) return type;
    }
    return null;
  }
}

/// Response from `POST /v1/grid/managed-networks` — a freshly created managed
/// (hosted) network on the control plane. Distinct from a self-hosted network
/// made with `grid network create` (which needs a local container engine).
class ManagedNetwork {
  const ManagedNetwork({
    required this.networkId,
    required this.name,
    required this.networkType,
    required this.signalingUrl,
    required this.port,
    required this.status,
    required this.plan,
  });

  final String networkId;
  final String name;
  final String networkType;
  final String signalingUrl;
  final int port;
  final String status;
  final String plan;

  factory ManagedNetwork.fromJson(Map<String, dynamic> json) {
    return ManagedNetwork(
      networkId: json['network_id'] as String,
      name: (json['name'] ?? '') as String,
      networkType: (json['network_type'] ?? '') as String,
      signalingUrl: (json['signaling_url'] ?? '') as String,
      port: (json['port'] ?? 0) as int,
      status: (json['status'] ?? '') as String,
      plan: (json['plan'] ?? '') as String,
    );
  }
}
