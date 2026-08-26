import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';

/// Current credentials, read from `~/.grid/credentials.toml`. Invalidate after
/// a login/sync to refresh.
final sessionProvider = Provider<CredentialsFile>((ref) {
  return ref.watch(gridHomeStoreProvider).readCredentials();
});

/// The active remote grid the user picked with `grid use`, read from
/// `~/.grid/state.json`. In the dual-mode CLI this replaced the old
/// `active_network` field in `credentials.toml`. Invalidate after a `grid use`.
final activeRemoteGridProvider = Provider<String?>((ref) {
  return ref.watch(gridHomeStoreProvider).readActiveRemoteGrid();
});

/// The network selected in the UI. Defaults to the `grid use` active grid from
/// `state.json`, then the legacy `active_network`, then the first grid;
/// switching is pure app state — we never rewrite on-disk state (the CLI owns it).
final selectedNetworkProvider =
    NotifierProvider<SelectedNetwork, NetworkCredential?>(SelectedNetwork.new);

class SelectedNetwork extends Notifier<NetworkCredential?> {
  /// The grid the user explicitly picked this session, remembered by id. A
  /// background refresh (e.g. the `grid sync` after starting an engine)
  /// invalidates [sessionProvider] and re-runs [build]; without this we'd snap
  /// back to the default/first grid and strand the user — resetting their view
  /// and bouncing them off the Engines tab. Re-resolving the same id keeps the
  /// selection put as long as the grid still exists in the refreshed list.
  String? _selectedId;

  @override
  NetworkCredential? build() => _adopt(_resolve());

  /// Hand the resolved grid down to every agent Grid spawns, and return it.
  ///
  /// Both write paths go through here — [build], which re-runs on every refresh
  /// of the credential list, and [select], which does not re-run it. A grid the
  /// app moved away from must stop being the one an agent's `search.py` posts
  /// to, and **null is a value here**: signing out or leaving the last grid has
  /// to take the credential away rather than leave the previous one live.
  NetworkCredential? _adopt(NetworkCredential? network) {
    HostEnvironment.adoptGrid(
      relayBaseUrl: network?.relayBaseUrl,
      relayToken: network?.relayApiKey,
    );
    return network;
  }

  NetworkCredential? _resolve() {
    final creds = ref.watch(sessionProvider);
    final active = ref.watch(activeRemoteGridProvider);
    // A live selection wins over the on-disk default, so a refresh doesn't move
    // the user — unless that grid vanished from the synced list.
    final picked = _selectedId == null ? null : creds.byName(_selectedId!);
    if (picked != null) return picked;
    // First selection this session: restore the grid the user last used, so
    // reopening the app lands on it rather than the CLI default. Skipped once
    // they've picked live (above), and only if that grid still exists.
    if (_selectedId == null) {
      final saved = ref.read(chatPrefsProvider).networkId;
      if (saved != null) {
        final match = creds.byName(saved);
        if (match != null) return match;
      }
    }
    if (active != null) {
      final match = creds.byName(active);
      if (match != null) return match;
    }
    return creds.active;
  }

  void select(NetworkCredential network) {
    _selectedId = network.networkId;
    state = _adopt(network);
    ref.read(chatPrefsProvider.notifier).setNetwork(network.networkId);
  }
}
