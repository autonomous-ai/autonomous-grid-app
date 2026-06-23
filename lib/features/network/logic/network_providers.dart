import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/network_config.dart';
import '../../auth/logic/session_controller.dart';

/// Local server config for the selected network, if it is locally managed.
/// Hosted networks have no `config.toml`, so this is null for them.
final selectedNetworkConfigProvider = Provider<NetworkConfig?>((ref) {
  final selected = ref.watch(selectedNetworkProvider);
  if (selected == null) return null;
  return ref.watch(gridHomeStoreProvider).readNetworkConfig(selected.networkId);
});
