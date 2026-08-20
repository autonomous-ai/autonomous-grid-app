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
const Set<String> kPublicNetworkTypes = {
  'permissionless',
  'permissioned-providers',
};

/// The managed-network access types accepted when creating a hosted grid. The
/// [wire] value is sent as `network_type` on `POST /managed-networks` and sets
/// who must be whitelisted:
///   - `permissionless`      → whitelist providers only (consumers open)
///   - `permissioned-public` → whitelist providers AND consumers (invite-only)
///
/// The wire names read backwards from the product: the value with "public" in
/// it is the **private** grid, and the one without is the public one. The
/// constants are named for what the user is choosing, so the lie stops at this
/// file — [wire] is the only place the backwards spelling appears.
enum ManagedNetworkType {
  public(
    'permissionless',
    'Public',
    'Whitelist providers only — consumers can join freely.',
  ),
  private(
    'permissioned-public',
    'Private',
    'Whitelist both providers and consumers.',
  );

  const ManagedNetworkType(this.wire, this.label, this.description);

  /// Value sent as `network_type` in the request body.
  final String wire;

  /// Human-readable name shown in the picker.
  final String label;

  /// One-line explanation shown under the picker.
  final String description;

  /// The API default when `network_type` is omitted.
  static const ManagedNetworkType fallback = ManagedNetworkType.public;
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
