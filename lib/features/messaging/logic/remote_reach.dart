import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'messaging_platform.dart';
import 'messaging_state.dart';
import 'telegram/telegram_messaging_controller.dart';

/// Whether this computer can be reached — and answer — from somewhere else.
///
/// The Messages screen already knows this, but it is one screen behind a
/// developer gate, so the fact that a machine is answering strangers' messages
/// lived nowhere a user would look. That is a thing to be able to see at a
/// glance: what this computer will do while you are not at it.
///
/// [answering] is the honest half — a connected bot whose poll or gateway is
/// down answers nobody.
typedef RemoteReach = ({bool connected, bool answering});

/// Whether a Telegram bot is connected here, and whether it is actually
/// answering right now.
///
/// Reads the same state the Messages screen does, so the two can't disagree;
/// a bot still loading counts as not connected rather than blocking the answer.
final remoteReachProvider = Provider<RemoteReach>((ref) {
  final state = ref.watch(telegramMessagingProvider).value;
  if (state is! MessagingConnected) return (connected: false, answering: false);
  return (connected: true, answering: state.link == MessagingLink.answering);
});

/// The one line the status row shows, or null when this computer answers nobody
/// from outside and there is nothing to say.
///
/// Three states rather than two, and the middle one is the point: a bot that is
/// connected but not answering must not read the same as one that is, or the
/// user believes their computer is reachable when it isn't (§5).
String? remoteReachLabel(RemoteReach reach) {
  if (!reach.connected) return null;
  final where = MessagingPlatform.telegram.label;
  return reach.answering
      ? 'Answering messages from $where'
      : '$where is connected, but nothing is answering messages right now';
}
