/// What a chat platform is on this computer, and whether it is really answering.
///
/// Kept apart from the controller because the honesty lives here: "a bot is
/// connected" and "a bot answers you" are different facts, and the mapping
/// between the gateway's raw signals and the word the screen shows is pure, so
/// it can be tested rather than guessed at in a widget.
library;

/// What a platform is on this computer.
sealed class MessagingState {
  const MessagingState();
}

/// No bot connected — the screen asks for one.
class MessagingDisconnected extends MessagingState {
  const MessagingDisconnected();
}

/// Whether a connected bot is actually answering right now — the honest half,
/// read from Hermes's own gateway state, not guessed from a heartbeat. A bot
/// being set up and the bot *answering* are different things.
enum MessagingLink {
  /// The gateway loaded the credentials and the platform is connected — messages
  /// get answered.
  answering,

  /// The gateway is bringing the bot up (connecting, or retrying after a blip).
  connecting,

  /// The gateway is off, or up but the bot didn't connect — see
  /// [MessagingConnected.detail] for which.
  notAnswering,
}

/// A bot is connected (its credentials are set). [link] is the honest half:
/// connected and *answering* are different things, and a bot whose gateway is
/// down — or whose token another process is polling — answers nobody.
class MessagingConnected extends MessagingState {
  const MessagingConnected({
    required this.allowedUsers,
    required this.link,
    this.detail,
  });

  /// Who may message it. Never empty — the app won't connect a bot without one.
  final List<String> allowedUsers;
  final MessagingLink link;

  /// Why it isn't answering, when [link] is [MessagingLink.notAnswering] — the
  /// gateway's own reason (a bad token, another process on the same bot) or the
  /// gateway simply being off. Null otherwise.
  final String? detail;
}

/// Map the gateway's raw signals to the honest UI link. [gatewayAlive] is the
/// heartbeat — is the gateway process up at all; [state]/[error] are the live
/// platform status from the gateway's state file. Pure so the mapping is
/// unit-tested rather than guessed at in a widget.
({MessagingLink link, String? detail}) messagingLinkFrom({
  required bool gatewayAlive,
  required String state,
  String? error,
}) {
  if (!gatewayAlive) {
    return (
      link: MessagingLink.notAnswering,
      detail: "The gateway that answers messages isn't running.",
    );
  }
  return switch (state) {
    'connected' => (link: MessagingLink.answering, detail: null),
    'connecting' ||
    'retrying' => (link: MessagingLink.connecting, detail: null),
    'disconnected' || 'fatal' || 'paused' => (
      link: MessagingLink.notAnswering,
      detail: error ?? "The bot didn't connect.",
    ),
    // Gateway is up but has no entry for this platform yet — the credentials
    // haven't loaded (e.g. added but the gateway wasn't restarted to pick
    // them up).
    _ => (
      link: MessagingLink.notAnswering,
      detail:
          error ?? "The bot's credentials haven't loaded into the gateway yet.",
    ),
  };
}
