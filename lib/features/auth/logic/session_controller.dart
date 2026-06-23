import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// Current credentials, read from `~/.grid/credentials.toml`. Invalidate after
/// a login/join to refresh.
final sessionProvider = Provider<CredentialsFile>((ref) {
  return ref.watch(gridHomeStoreProvider).readCredentials();
});

/// The network selected in the UI. Defaults to the on-disk `active_network`;
/// switching is pure app state — we never rewrite the TOML (the CLI owns it).
final selectedNetworkProvider =
    NotifierProvider<SelectedNetwork, NetworkCredential?>(SelectedNetwork.new);

class SelectedNetwork extends Notifier<NetworkCredential?> {
  @override
  NetworkCredential? build() => ref.watch(sessionProvider).active;

  void select(NetworkCredential network) => state = network;
}
