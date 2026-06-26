import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/cli_auth.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// The signed-in session, read from `~/.grid/cli.toml [auth]` — the file
/// `grid auth login` writes in grid 0.1.0. This is the login gate; invalidate
/// after a login/logout to refresh.
final authSessionProvider = Provider<CliAuth>((ref) {
  return ref.watch(gridHomeStoreProvider).readCliAuth();
});

/// Current credentials, read from `~/.grid/credentials.toml`. Holds the joined
/// networks. Invalidate after a login/join to refresh.
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
