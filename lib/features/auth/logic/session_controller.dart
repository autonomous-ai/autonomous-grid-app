import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// Current credentials, read from `~/.grid/credentials.toml`. Invalidate after
/// a login/sync to refresh.
final sessionProvider = Provider<CredentialsFile>((ref) {
  return ref.watch(gridHomeStoreProvider).readCredentials();
});

/// The active cloud grid the user picked with `grid use`, read from
/// `~/.grid/state.json`. In the dual-mode CLI this replaced the old
/// `active_network` field in `credentials.toml`. Invalidate after a `grid use`.
final activeCloudGridProvider = Provider<String?>((ref) {
  return ref.watch(gridHomeStoreProvider).readActiveCloudGrid();
});

/// The network selected in the UI. Defaults to the `grid use` active grid from
/// `state.json`, then the legacy `active_network`, then the first grid;
/// switching is pure app state — we never rewrite on-disk state (the CLI owns it).
final selectedNetworkProvider =
    NotifierProvider<SelectedNetwork, NetworkCredential?>(SelectedNetwork.new);

class SelectedNetwork extends Notifier<NetworkCredential?> {
  @override
  NetworkCredential? build() {
    final creds = ref.watch(sessionProvider);
    final active = ref.watch(activeCloudGridProvider);
    if (active != null) {
      final match = creds.byName(active);
      if (match != null) return match;
    }
    return creds.active;
  }

  void select(NetworkCredential network) => state = network;
}
