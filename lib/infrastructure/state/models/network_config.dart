/// Parsed `~/.grid/networks/<id>/config.toml` (network_runtime.py:104).
///
/// This replaces parsing `grid network status` entirely — the same fields the
/// status command prints (cli.py:583) are read straight off disk. See
/// CLI_Integration_Contract §1.2.
class NetworkConfig {
  const NetworkConfig({
    required this.networkId,
    required this.name,
    required this.networkType,
    required this.lanSignalingUrl,
    required this.port,
    required this.serverPid,
    required this.syncPid,
    required this.postgresContainer,
    required this.managedServer,
  });

  final String networkId;
  final String name;
  final String networkType;
  final String lanSignalingUrl;
  final int port;
  final int serverPid;
  final int syncPid;
  final String postgresContainer;
  final bool managedServer;

  factory NetworkConfig.fromToml(Map<String, dynamic> t) {
    return NetworkConfig(
      networkId: t['network_id'] as String,
      name: (t['name'] ?? t['network_id']) as String,
      networkType: (t['network_type'] ?? 'permissioned') as String,
      lanSignalingUrl: (t['lan_signaling_url'] ?? '') as String,
      port: (t['port'] ?? 0) as int,
      serverPid: (t['server_pid'] ?? 0) as int,
      syncPid: (t['sync_pid'] ?? 0) as int,
      postgresContainer: (t['postgres_container'] ?? '') as String,
      managedServer: (t['managed_server'] ?? true) as bool,
    );
  }

  /// Liveness probe target — the CLI's private server health endpoint
  /// (network_runtime.py:310). Pair this with [hasServerPid].
  String get serverInfoUrl => 'http://127.0.0.1:$port/server/info';

  bool get hasServerPid => serverPid != 0;

  bool get hasSyncPid => syncPid != 0;
}
