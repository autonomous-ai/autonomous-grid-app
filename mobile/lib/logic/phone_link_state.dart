/// Where the link to the paired computer has got to.
///
/// A sealed type rather than a handful of booleans, so every screen has to say
/// what it shows in each case and "connected but also failed" cannot be built.
library;

/// One grid, as much of it as the computer is willing to say.
typedef GridRow = ({String id, String name, String type, String email});

/// Where the link has got to.
sealed class PhoneLinkState {
  const PhoneLinkState();
}

/// No computer paired yet.
final class PhoneLinkUnpaired extends PhoneLinkState {
  const PhoneLinkUnpaired();
}

/// Working on it, with something honest to show while it happens.
///
/// Only for a phone that has nothing to show yet — opening the app, or pairing.
/// A link that drops *after* it was up is [PhoneLinkInterrupted] instead, so
/// the screen somebody was reading stays where it was.
final class PhoneLinkConnecting extends PhoneLinkState {
  const PhoneLinkConnecting(this.step);

  /// What is being attempted right now.
  final String step;
}

/// Through, with what the computer said.
final class PhoneLinkConnected extends PhoneLinkState {
  const PhoneLinkConnected({
    required this.hostName,
    required this.platform,
    required this.appVersion,
    required this.grids,
    required this.session,
    this.methods = const {},
  });

  /// What the computer calls itself.
  final String hostName;

  /// macos, linux or windows.
  final String platform;

  /// Which Grid it is running.
  final String appVersion;

  /// The grids it is signed in to.
  final List<GridRow> grids;

  /// What the computer answers — the phone offers Stop and the permission
  /// card only where they will work. Empty from a desktop too old to say,
  /// which reads as "neither" rather than as buttons it would refuse.
  final Set<String> methods;

  /// Whether this computer can stop an answer from the phone.
  bool get canStop => methods.contains('chats.stop');

  /// Whether this computer takes the agent's questions answered from here.
  bool get canAnswer => methods.contains('chats.answer');

  /// Which dial this is — one more on every fresh connection.
  ///
  /// What the lists re-ask on ([phoneLinkSessionProvider]). An answer that
  /// failed while the link was down is an error on screen, and without a
  /// signal that the link is back it stays one until somebody pulls to refresh.
  final int session;

  /// The same link with fresh answers from the computer.
  PhoneLinkConnected refreshed({
    required String platform,
    required String appVersion,
    required List<GridRow> grids,
    required Set<String> methods,
  }) => PhoneLinkConnected(
    hostName: hostName,
    platform: platform,
    appVersion: appVersion,
    grids: grids,
    session: session,
    methods: methods,
  );
}

/// Was through, dropped, and is being put back — the app stays on screen.
///
/// **Why this is not [PhoneLinkFailed].** A phone is locked and unlocked all
/// day, and iOS ends the socket every time. Treated as a failure, each unlock
/// replaced the whole app with "Can't reach your computer" and threw away the
/// tab and the chat somebody had open, for a link the next dial restored in a
/// second. [last] is what the screens keep drawing meanwhile.
final class PhoneLinkInterrupted extends PhoneLinkState {
  const PhoneLinkInterrupted(this.last, {this.problem});

  /// The link as it was when it dropped.
  final PhoneLinkConnected last;

  /// Why the last attempt to put it back failed, or null while one is running.
  final String? problem;
}

/// It did not work, and the message says what to do about it.
final class PhoneLinkFailed extends PhoneLinkState {
  const PhoneLinkFailed(this.message, {required this.stillPaired});

  /// Shown to the person as-is.
  final String message;

  /// Whether Reconnect is worth offering, or whether this needs a new code.
  final bool stillPaired;
}

/// The link the app is drawing — live, or the last one while it comes back.
///
/// Null before the first connection, when there is nothing to draw.
PhoneLinkConnected? shownLink(PhoneLinkState state) => switch (state) {
  final PhoneLinkConnected live => live,
  PhoneLinkInterrupted(:final last) => last,
  _ => null,
};

/// The grids in a `grids.list` answer.
List<GridRow> readGridRows(Map<String, Object?> result) {
  final rows = result['grids'];
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map)
        (
          id: '${row['id'] ?? ''}',
          name: '${row['name'] ?? ''}',
          type: '${row['type'] ?? ''}',
          email: '${row['email'] ?? ''}',
        ),
  ];
}

/// The methods a `status.get` answer says the computer takes.
Set<String> readMethods(Map<String, Object?> status) => {
  for (final method
      in status['methods'] is List ? status['methods']! as List : const [])
    if (method is String) method,
};
