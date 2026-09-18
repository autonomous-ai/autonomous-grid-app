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

/// How often an open chat asks whether it has moved, when nothing is running.
///
/// Slow enough to be nearly free — two numbers — and fast enough that an answer
/// arriving at the computer shows up before somebody wonders whether it did.
const Duration _askEvery = Duration(seconds: 3);

/// How often it asks while an answer is being written.
///
/// Much faster, because this is the poll that *is* the stream: each reply
/// carries the whole answer so far, so the gap between asks is the gap between
/// the words appearing. Three seconds made the reply arrive in visible lurches
/// while the computer showed it flowing.
const Duration _askWhileWriting = Duration(milliseconds: 700);

/// What one chat is doing right now.
///
/// A value rather than a void watcher: [streaming] is the answer as far as it
/// has been written, and the screen draws it as the trailing bubble. That is
/// what makes a reply appear as it is typed instead of all at once when the
/// turn finally lands on disk.
typedef LiveTurn = ({int total, String streaming});

/// Watches one chat while its screen is open.
///
/// Holds the turn count it last saw. Only a *change* re-reads the page, so the
/// common answer — nothing happened — costs one tiny request and no redraw.
final chatWatchProvider = NotifierProvider.family<ChatWatch, LiveTurn, String>(
  ChatWatch.new,
);

/// Polls one chat's head and re-reads the transcript when it moves.
class ChatWatch extends Notifier<LiveTurn> {
  ChatWatch(this.chatId);

  /// The conversation being watched — the family argument.
  final String chatId;

  Timer? _timer;
  Duration? _rate;
  int? _lastTotal;
  bool _asking = false;

  @override
  LiveTurn build() {
    _schedule(_askEvery);
    ref.onDispose(() => _timer?.cancel());
    return (total: 0, streaming: '');
  }

  /// Re-arms the timer at [every], if it is not already running at that rate.
  ///
  /// Two rates rather than one fast one: polling every 700ms all day would keep
  /// a phone's radio awake for a chat nobody is talking in.
  void _schedule(Duration every) {
    if (_rate == every && _timer != null) return;
    _rate = every;
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => _ask());
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
      final streaming = '${head['streaming'] ?? ''}';
      _schedule(busy ? _askWhileWriting : _askEvery);

      // The live reply first, and on its own: it changes on nearly every poll
      // while a turn runs, and re-reading the page each time would fetch forty
      // finished turns to redraw one growing bubble.
      if (streaming != state.streaming || total != state.total) {
        state = (total: total, streaming: streaming);
      }
      if (total == _lastTotal) return;
      _lastTotal = total;
      // The turn landed on disk. Now the page is worth re-reading — and the
      // streamed bubble disappears because the real one has taken its place.
      ref.invalidate(transcriptProvider((id: chatId, offset: null)));
    } on RelayPhoneFailure {
      // The link is down. Nothing to do here: the next tap re-dials on its own
      // and the screen already says the link dropped.
    } finally {
      _asking = false;
    }
  }
}
