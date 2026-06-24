import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider_node/logic/provider_run_controller.dart';

/// Whether the Playground sends to the local provider over HTTP instead of the
/// relay. Kept in app state (not widget state) so it survives tab switches, and
/// auto-resets to off the moment the local provider stops — so it never targets
/// a dead server. Driven off [localProviderEndpointProvider].
final useLocalTestProvider =
    NotifierProvider<UseLocalTestNotifier, bool>(UseLocalTestNotifier.new);

class UseLocalTestNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Turn off only when the local provider goes away (endpoint becomes null).
    ref.listen(localProviderEndpointProvider, (_, next) {
      if (next == null) state = false;
    });
    return false;
  }

  void set(bool value) => state = value;
}
