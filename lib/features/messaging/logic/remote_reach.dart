import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'messaging_controller.dart';
import 'messaging_platform.dart';

/// Whether this computer can be reached — and answer — from somewhere else.
///
/// The Messages screen already knows this per platform, but it is one screen
/// behind a developer gate, so the fact that a machine is answering strangers'
/// messages lived nowhere a user would look. That is a thing to be able to see
/// at a glance: what this computer will do while you are not at it.
///
/// [answering] is the honest half — a connected bot whose gateway is down
/// answers nobody (see [messagingLinkFrom]).
typedef RemoteReach = ({List<String> platforms, bool answering});

/// Which platforms are connected on this computer, and whether any is actually
/// answering right now.
///
/// Reads the same per-platform state the Messages screen does, so the two can't
/// disagree; a platform still loading counts as not connected rather than
/// blocking the answer.
final remoteReachProvider = Provider<RemoteReach>((ref) {
  final connected = <String>[];
  var answering = false;
  for (final platform in MessagingPlatform.values) {
    final state = ref.watch(messagingProvider(platform)).value;
    if (state is! MessagingConnected) continue;
    connected.add(platform.label);
    if (state.link == MessagingLink.answering) answering = true;
  }
  return (platforms: List.unmodifiable(connected), answering: answering);
});

/// The one line the status row shows, or null when this computer answers nobody
/// from outside and there is nothing to say.
///
/// Three states rather than two, and the middle one is the point: a bot that is
/// connected but not answering must not read the same as one that is, or the
/// user believes their computer is reachable when it isn't (§5).
String? remoteReachLabel(RemoteReach reach) {
  if (reach.platforms.isEmpty) return null;
  final where = _list(reach.platforms);
  return reach.answering
      ? 'Answering messages from $where'
      : '$where is connected, but nothing is answering messages right now';
}

String _list(List<String> names) {
  if (names.length == 1) return names.first;
  final rest = names.sublist(0, names.length - 1).join(', ');
  return '$rest and ${names.last}';
}
