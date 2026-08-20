/// The managed-network access types accepted when creating a hosted grid. The
/// [wire] value is sent as `network_type` on `POST /managed-networks` and sets
/// who must be whitelisted:
///   - `permissioned-public`    → whitelist providers AND consumers (invite-only)
///   - `permissionless` → whitelist providers only (consumers open)
///
/// User-facing, that maps "Public" to `permissionless` (consumers join
/// freely) and "Private" to `permissioned-public` (everyone whitelisted). The
/// [label]/[description] drive the create form. NOTE: the enum constant names do
/// not track [wire] after that swap — trust [wire]/[label], not the name.
enum ManagedNetworkType {
  permissionedPublic(
    'permissionless',
    'Public',
    'Whitelist providers only — consumers can join freely.',
  ),
  permissionedProviders(
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
  static const ManagedNetworkType fallback =
      ManagedNetworkType.permissionedPublic;
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
