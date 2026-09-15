/// Keeping an open chat up to date with the computer.
///
/// The phone had no way of hearing that a chat had moved: it read the
/// transcript once when the screen opened and then sat on it, so a message
/// typed at the computer — or an answer that arrived a moment later — simply
/// was not there. The screen looked finished, which is the worst way to be
/// wrong (§5).
///
/// Polling rather than a pushed frame. The channel could carry one, but replies
/// are correlated to requests by id and teaching both ends to accept
/// unsolicited frames is a protocol change; [chats.head] is two numbers, and
/// asking for them on a timer costs less than that change would.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_chats.dart';
import 'phone_link_controller.dart';
import 'relay_phone_client.dart';

/// How often an open chat asks whether it has moved.
///
/// Slow enough to be nearly free — two numbers — and fast enough that an answer
/// arriving at the computer shows up before somebody wonders whether it did.
const Duration _askEvery = Duration(seconds: 3);

/// Watches one chat while its screen is open.
///
/// Holds the turn count it last saw. Only a *change* invalidates the page, so
/// the common answer — nothing happened — costs one tiny request and no redraw.
final chatWatchProvider = NotifierProvider.family<ChatWatch, int, String>(
  ChatWatch.new,
);

/// Polls one chat's head and re-reads the transcript when it moves.
class ChatWatch extends Notifier<int> {
  ChatWatch(this.chatId);

  /// The conversation being watched — the family argument.
  final String chatId;

  Timer? _timer;
  int? _lastTotal;
  bool _asking = false;

  @override
  int build() {
    _timer = Timer.periodic(_askEvery, (_) => _ask());
    ref.onDispose(() => _timer?.cancel());
    return 0;
  }

  Future<void> _ask() async {
    // One in flight at a time: a slow link would otherwise stack requests the
    // timer keeps adding to, and each is a frame through an AEAD channel.
    if (_asking) return;
    _asking = true;
    try {
      final head = await ref.read(phoneLinkProvider.notifier).call(
        'chats.head',
        {'id': chatId},
      );
      final total = head['total'];
      if (total is! int) return;
      final busy = head['busy'] == true;
      // Re-read on a changed turn count, and also while an answer is being
      // written: the last turn grows in place as it streams, so its text
      // changes without the count moving.
      if (total == _lastTotal && !busy) return;
      _lastTotal = total;
      state = total;
      ref.invalidate(transcriptProvider((id: chatId, offset: null)));
    } on RelayPhoneFailure {
      // The link is down. Nothing to do here: the next tap re-dials on its own
      // and the screen already says the link dropped.
    } finally {
      _asking = false;
    }
  }
}
