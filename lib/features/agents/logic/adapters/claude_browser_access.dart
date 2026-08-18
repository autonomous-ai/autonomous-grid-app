import '../../../../infrastructure/cli/chrome_extension_probe.dart';
import '../agent_model_support.dart';
import 'claude_browser.dart';

/// The one setup step a user can act on from the browser card.
///
/// Only the two that have a button. Everything else that shuts the user's own
/// Chrome out (a grid model answering, a Claude Code too old for the flag) is
/// said in the card's own sentence instead — inventing a button for something
/// the card cannot do is worse than a plain explanation.
enum BrowserSetupStep {
  /// Open the Chrome Web Store page for Claude in Chrome.
  installExtension,

  /// Write the connection Chrome talks to again. The app already does this at
  /// launch, so this is the retry for a machine where that didn't take — see
  /// `ChromeSetupController`.
  connectChrome,
}

/// What the assistant can reach right now, in the user's words.
///
/// [lane] is the same lane [planClaudeBrowser] would pick for the next turn —
/// derived from it, never re-decided here, so the card cannot promise a browser
/// the turn won't take.
typedef BrowserAccess = ({
  ClaudeBrowserLane lane,
  String title,
  String detail,
  BrowserSetupStep? step,
});

/// Which browser the next turn gets, and what to do about it.
///
/// The app knew all of this already and told only the log: "the agent won't
/// touch my browser" was a question whose answer lived in `~/.grid/logs`. Pure,
/// and unit-tested, because every branch here is a sentence a non-technical
/// user acts on (§5).
///
/// [hasChrome] and [hasNodeRunner] are the two halves of the fallback lane, kept
/// apart so the dead end can name the missing piece rather than shrug.
BrowserAccess describeBrowserAccess({
  required String model,
  required ChromeExtensionState extensionState,
  required bool cliSupportsChrome,
  required bool hasChrome,
  required bool hasNodeRunner,
  required bool cdpAllowed,
}) {
  final plan = planClaudeBrowser(
    model: model,
    extensionState: extensionState,
    cliSupportsChrome: cliSupportsChrome,
    cdpReady: hasChrome && hasNodeRunner,
    cdpAllowed: cdpAllowed,
  );
  final blocked = _yourChromeBlocked(
    seat: isClaudeSeatModel(model),
    cliSupportsChrome: cliSupportsChrome,
    extensionState: extensionState,
  );
  return switch (plan.lane) {
    ClaudeBrowserLane.extension => (
      lane: plan.lane,
      title: 'Works in your Chrome',
      detail:
          'The assistant uses the Chrome you already have open, so every '
          'account you are signed in to is there too.',
      step: null,
    ),
    ClaudeBrowserLane.cdp => (
      lane: plan.lane,
      title: 'Works in a separate window',
      detail:
          'Grid opens a Chrome of its own. It is signed in to nothing, so '
                  'anything behind a login stays out of reach. ${blocked?.why ?? ''}'
              .trim(),
      step: blocked?.step,
    ),
    ClaudeBrowserLane.none => (
      lane: plan.lane,
      title: 'No browser yet',
      detail:
          '${_noBrowserReason(cdpAllowed: cdpAllowed, hasChrome: hasChrome, hasNodeRunner: hasNodeRunner)} '
                  '${blocked?.why ?? ''}'
              .trim(),
      step: blocked?.step,
    ),
  };
}

/// Why the assistant is not in the user's own Chrome, and the step that would
/// put it there. Null once nothing is in the way.
({String why, BrowserSetupStep? step})? _yourChromeBlocked({
  required bool seat,
  required bool cliSupportsChrome,
  required ChromeExtensionState extensionState,
}) {
  if (!seat) {
    return (
      why:
          'To use your own Chrome, pick a Claude model for this chat — the '
          'others answer through the grid, which Chrome turns away.',
      step: null,
    );
  }
  if (!cliSupportsChrome) {
    return (
      why:
          'Update Claude Code with the button above and it can use your own '
          'Chrome.',
      step: null,
    );
  }
  return switch (extensionState) {
    ChromeExtensionState.missing => (
      why:
          'Add the Claude in Chrome extension to let it work in the browser '
          'you already use.',
      step: BrowserSetupStep.installExtension,
    ),
    ChromeExtensionState.hostPending => (
      why:
          'One step left, and it is yours: open Chrome — quit and reopen it if '
          'it is already running — so it picks up the connection Grid set up.',
      step: BrowserSetupStep.connectChrome,
    ),
    ChromeExtensionState.ready => null,
  };
}

/// Why there is no browser at all — the switch is off, or the machine is
/// missing a piece the separate window needs.
String _noBrowserReason({
  required bool cdpAllowed,
  required bool hasChrome,
  required bool hasNodeRunner,
}) {
  if (!cdpAllowed) {
    return 'Nothing here opens a browser while you chat.';
  }
  if (!hasChrome) {
    return 'Grid found no Chrome on this computer to open.';
  }
  if (!hasNodeRunner) {
    return 'Grid needs Node.js installed before it can drive a browser window.';
  }
  return 'Grid could not reach a browser on this computer.';
}
