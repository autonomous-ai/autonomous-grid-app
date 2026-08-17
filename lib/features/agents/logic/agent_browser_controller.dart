import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../chat/logic/chat_scope.dart';
import 'adapters/claude_browser_access.dart';
import 'adapters/claude_tool.dart';

/// Whether the assistant may open a browser on this computer — the value the
/// switch shows, read on its own so the row doesn't rebuild on every model or
/// font change.
final agentBrowserAllowedProvider = Provider<bool>(
  (ref) => ref.watch(chatPrefsProvider.select((prefs) => prefs.agentBrowser)),
);

/// How far this computer is from letting a turn drive the user's own Chrome.
///
/// Cached, unlike the per-turn probe it reads: a card that re-probed the disk on
/// every rebuild would flicker, and the two things that change the answer —
/// installing the extension, restarting Chrome — both happen *outside* the app,
/// so the user tells us with "Check again" ([AgentBrowserController.recheck]).
final chromeExtensionStateProvider = Provider<ChromeExtensionState>(
  (ref) => ref.watch(chromeExtensionProbeProvider).detect(),
);

/// Which browser the chat on screen would get on its next turn, and what the
/// user can do about it.
///
/// Reads the model of the chat on screen rather than a global one: the browser a
/// turn reaches depends on what answers it, and in this app that is a per-chat
/// (per-project) choice.
final browserAccessProvider = Provider<BrowserAccess>(
  (ref) => describeBrowserAccess(
    model: ref.watch(chatScopeModelProvider) ?? '',
    extensionState: ref.watch(chromeExtensionStateProvider),
    // Unresolved reads as "no": the flag is the difference between a turn that
    // drives Chrome and one that is rejected for passing it, and the probe
    // settles in milliseconds.
    cliSupportsChrome: ref.watch(claudeSupportsChromeProvider).value ?? false,
    hasChrome: ref.watch(chromeBinaryProvider) != null,
    hasNodeRunner: ref.watch(npxPathProvider) != null,
    cdpAllowed: ref.watch(agentBrowserAllowedProvider),
  ),
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

  /// Look at this computer again after the user went off and changed it.
  ///
  /// Both blockers on the user's own Chrome are fixed outside this app — an
  /// extension installed in the browser, a Chrome restarted — and neither sends
  /// the app a signal. Without this the card keeps stating a problem the user
  /// has already solved, which reads as the setup not working.
  void recheck() {
    _ref.invalidate(chromeExtensionStateProvider);
    _ref.invalidate(claudeSupportsChromeProvider);
  }
}
