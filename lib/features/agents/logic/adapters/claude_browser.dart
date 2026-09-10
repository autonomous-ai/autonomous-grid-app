import '../../../../core/subscription_model.dart';
import '../../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../../infrastructure/state/agent_browser_choice.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../agent_model_support.dart';
import '../mcp_server.dart';

/// How a Claude Code turn reaches a browser, if it reaches one at all.
///
/// Two lanes rather than one because the two ways of driving a browser have
/// opposite requirements, and neither covers both cases:
///
/// - [extension] is the user's **own** Chrome — the windows and the logins they
///   already have. It is open whenever a browser is holding the bridge socket
///   (`ChromeExtensionProbe`), and the connection behind that is written at
///   launch (`ChromeHostInstaller`). Claude Code only talks to the extension
///   when the session is signed in with a claude.ai account, so it is closed to
///   any turn carrying the relay's `ANTHROPIC_*` credentials (Claude Code turns
///   Chrome off for API-key sessions; older builds left it on and 403'd every
///   call).
/// - [cdp] is a browser this app starts and keeps, reached over the DevTools
///   protocol by an MCP server. It works with any model and any credential —
///   and it is a fresh profile, so it is signed in to nothing.
enum ClaudeBrowserLane {
  /// `claude --chrome`, against the user's own browser.
  extension,

  /// A `chrome-devtools` MCP server against the app's own browser.
  cdp,

  /// No browser this turn.
  none,
}

/// The lane a turn takes and the sentence the log records for it.
///
/// The reason travels with the lane because "the agent didn't use the browser"
/// is the failure users report, and a lane without a reason leaves the log
/// saying only which door was taken, never why the other was shut.
typedef ClaudeBrowserPlan = ({ClaudeBrowserLane lane, String reason});

/// Which browser lane a turn on [model] can take. Pure, and unit-tested: the
/// wrong lane fails silently — a turn that quietly has no browser tools reads
/// exactly like a model that decided not to browse.
///
/// The extension is preferred over a clean window wherever both are on offer,
/// because it is the browser the user actually meant: their tabs, their
/// sessions, their logins.
///
/// **Both lanes are the user's own choice**, and neither runs unasked. That is
/// the change [AgentBrowserChoice] made: [cdpAllowed] was always a switch,
/// because that lane *starts a browser window* and doing that because somebody
/// typed a message is the behaviour it exists to stop — but [extensionAllowed]
/// used to be no switch at all, on the reasoning that installing the extension
/// was consent enough. It is the stronger of the two: it acts as the user in
/// every account they are signed in to.
ClaudeBrowserPlan planClaudeBrowser({
  required String model,
  required ChromeExtensionState extensionState,
  required bool cliSupportsChrome,
  required bool cdpReady,
  required bool cdpAllowed,
  required bool extensionAllowed,
}) {
  // Whichever way this turn already runs on Claude Code's own sign-in: a
  // `claude:*` seat, which is Claude Code answering behind the relay, or the
  // subscription row, which is Claude Code answering on the user's own account
  // with no relay at all. The extension only talks to a session signed in with
  // a claude.ai account, and both of these are one.
  final ownSignIn = isClaudeSeatModel(model) || isSubscriptionModelId(model);
  final connected = extensionState == ChromeExtensionState.ready;
  if (extensionAllowed && ownSignIn && cliSupportsChrome && connected) {
    return (
      lane: ClaudeBrowserLane.extension,
      reason:
          "Claude Code's own sign-in answers this turn and the Chrome "
          'extension is connected',
    );
  }
  if (!cdpAllowed) {
    return (
      lane: ClaudeBrowserLane.none,
      reason:
          'the assistant is not allowed to open a browser '
          '(Settings ▸ Browser)',
    );
  }
  if (cdpReady) {
    return (
      lane: ClaudeBrowserLane.cdp,
      reason: _cdpReason(
        ownSignIn: ownSignIn,
        cliSupportsChrome: cliSupportsChrome,
        extensionState: extensionState,
      ),
    );
  }
  return (
    lane: ClaudeBrowserLane.none,
    reason: _noneReason(extensionState: extensionState),
  );
}

/// Why the turn is on the app's own browser rather than the user's. Names the
/// one thing that shut the extension out, so the log points at a fix.
String _cdpReason({
  required bool ownSignIn,
  required bool cliSupportsChrome,
  required ChromeExtensionState extensionState,
}) {
  if (!ownSignIn) {
    return 'the grid model answers this turn, so the extension (which needs '
        "Claude Code's own sign-in) is out";
  }
  if (!cliSupportsChrome) return 'this Claude Code build has no --chrome';
  return switch (extensionState) {
    ChromeExtensionState.missing =>
      'the Claude in Chrome extension is not '
          'installed',
    ChromeExtensionState.hostPending =>
      'no browser has connected to the Chrome extension yet — Chrome has to '
          'be restarted once after the connection was installed',
    ChromeExtensionState.ready => 'the extension is ready but was not chosen',
  };
}

/// Why this turn has no browser at all.
String _noneReason({required ChromeExtensionState extensionState}) =>
    switch (extensionState) {
      ChromeExtensionState.missing =>
        'no Claude in Chrome extension and no browser this app can drive',
      ChromeExtensionState.hostPending =>
        'no browser has connected to the extension yet, and no fallback '
            'browser is available',
      ChromeExtensionState.ready =>
        'the extension is installed but this model cannot use it, and no '
            'fallback browser is available',
    };

/// Everything that points Claude Code at the relay instead of at Anthropic.
///
/// A turn on the [ClaudeBrowserLane.extension] lane has to reach Claude Code's
/// own claude.ai sign-in, so these are stripped from its environment rather than
/// merely left unset: the app's own process can be carrying one (a developer who
/// exported it), and one leftover variable is the difference between the user's
/// browser opening and browser calls the extension refuses.
final Set<String> kClaudeRelayEnvKeys = {
  kClaudeBaseUrlEnv,
  kClaudeAuthTokenEnv,
  kClaudeApiKeyEnv,
  kClaudeModelEnv,
  kClaudeSmallFastModelEnv,
  kClaudeSubagentModelEnv,
  kClaudeCompactWindowEnv,
  ...kClaudeTierModelEnv.values,
};

/// The name the browser MCP server is configured under, and so the prefix its
/// tools reach the turn with (`mcp__chrome-devtools__navigate_page`).
const String kChromeDevtoolsServerName = 'chrome-devtools';

/// What Claude Code calls the extension's server in the `init` line it opens a
/// turn with. Measured on 2.1.183, not guessed — it is the name the app watches
/// for to know the browser tools actually arrived.
const String kClaudeInChromeServer = 'claude-in-chrome';

/// The MCP entry that hands a turn the app's own browser: the published server,
/// pointed at a DevTools endpoint that is already up.
///
/// Built through [McpServer] rather than a hand-written map so it carries the
/// same shape every other stdio server in this app is written with.
///
/// `npx -y` fetches the package the first time, so the first browser turn on a
/// machine pays a download the later ones don't — worth knowing when a turn
/// looks slow to start rather than slow to think.
Map<String, Object?> chromeDevtoolsEntry({
  required String npxPath,
  required String browserUrl,
}) => McpServer(
  name: kChromeDevtoolsServerName,
  transport: McpStdio(
    command: npxPath,
    args: ['-y', kChromeDevtoolsMcpPackage, '--browser-url', browserUrl],
  ),
).toConfigValue();

/// The model name a **locally run** Claude Code takes for a seat model.
///
/// A seat is named for the relay (`claude:opus`); run directly, the same brain
/// is `opus`. Passing the seat name through would reach `claude --model
/// claude:opus`, which is not a model it knows.
String claudeLocalModel(String seatModel) {
  final first = seatModel.split(',').first.trim();
  final cut = first.indexOf(':');
  final tier = cut == -1 ? first : first.substring(cut + 1);
  return tier.trim().isEmpty ? first : tier.trim();
}
