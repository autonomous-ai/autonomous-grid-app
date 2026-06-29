/// The two network types the control plane accepts when creating a managed
/// (hosted) network. The wire value is exactly what the API expects in
/// `network_type`; the label/description drive the create form.
enum ManagedNetworkType {
  permissionedPublic(
    'permissioned-public',
    'Use and share models',
    'People you invite can both use models and run their own on this grid.',
  ),
  permissionedProviders(
    'permissioned-providers',
    'Share models only',
    'Only people who run a model can join — there are no use-only members.',
  );

  const ManagedNetworkType(this.wire, this.label, this.description);

  /// Value sent as `network_type` in the request body.
  final String wire;

  /// Human-readable name shown in the picker.
  final String label;

  /// One-line explanation under the picker.
  final String description;

  /// The API default when `network_type` is omitted.
  static const ManagedNetworkType fallback = ManagedNetworkType.permissionedPublic;
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
