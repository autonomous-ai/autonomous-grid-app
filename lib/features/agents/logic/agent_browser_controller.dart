import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../infrastructure/state/agent_browser_choice.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../chat/logic/chat_scope.dart';
import 'adapters/claude_browser_access.dart';
import 'adapters/claude_tool.dart';

/// Which browser the assistant may reach for — the value the control in
/// Settings ▸ Browser shows, read on its own so nothing rebuilds on every model
/// or font change.
final agentBrowserChoiceProvider = Provider<AgentBrowserChoice>(
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
    // The one choice, read as the two lanes it can name. Neither runs unasked.
    cdpAllowed:
        ref.watch(agentBrowserChoiceProvider) == AgentBrowserChoice.cleanWindow,
    extensionAllowed:
        ref.watch(agentBrowserChoiceProvider) == AgentBrowserChoice.yourBrowser,
  ),
);

/// The control behind "which browser the assistant uses".
///
/// A controller rather than a bare setter because moving *off* the clean window
/// has to do something in the world: the app holds the browser it started for
/// the life of the app, so a plain preference write would leave a Chrome window
/// standing there after the user just picked something else.
final agentBrowserProvider = Provider<AgentBrowserController>(
  AgentBrowserController.new,
);

class AgentBrowserController {
  const AgentBrowserController(this._ref);

  final Ref _ref;

  /// Remember the choice, and make it true right now.
  ///
  /// Only the closing half happens here. Picking a browser opens nothing: it
  /// starts when a turn actually takes that lane, so an answer doesn't put a
  /// window on screen before there is anything for it to do.
  void choose(AgentBrowserChoice choice) {
    _ref.read(chatPrefsProvider.notifier).setAgentBrowser(choice);
    // Anything but the clean window means the Chrome the app started is no
    // longer the answer to anything — including [AgentBrowserChoice.none],
    // which is the user saying so outright.
    if (choice == AgentBrowserChoice.cleanWindow) return;
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
