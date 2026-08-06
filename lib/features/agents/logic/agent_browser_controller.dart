import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';

/// Whether the assistant may open a browser on this computer — the value the
/// switch shows, read on its own so the row doesn't rebuild on every model or
/// font change.
final agentBrowserAllowedProvider = Provider<bool>(
  (ref) => ref.watch(chatPrefsProvider.select((prefs) => prefs.agentBrowser)),
);

/// The switch behind "let the assistant open a browser".
///
/// A controller rather than a bare setter because turning it **off** has to do
/// something in the world: the app holds the browser it started for the life of
/// the app, so a plain preference write would leave a Chrome window standing
/// there after the user just said no to it. Off closes it.
final agentBrowserProvider = Provider<AgentBrowserController>(
  AgentBrowserController.new,
);

class AgentBrowserController {
  const AgentBrowserController(this._ref);

  final Ref _ref;

  /// Remember the choice, and make it true right now.
  ///
  /// Only the closing half happens here. Turning it *on* opens nothing: the
  /// browser starts when a turn actually takes that lane, so saying yes doesn't
  /// put a window on screen before there is anything for it to do.
  void allow(bool allowed) {
    _ref.read(chatPrefsProvider.notifier).setAgentBrowser(allowed);
    if (allowed) return;
    _ref.read(chromeBridgeProvider).dispose();
  }
}
