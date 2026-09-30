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
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';

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

/// How long a send keeps the fast rate before the computer says it is busy.
///
/// The computer accepts a message and *then* starts the turn — after any turn
/// already running in that chat has finished — so the first answer or two can
/// still say "not busy". Dropping to the slow rate on that would hide the start
/// of the answer for up to [_askEvery].
const Duration _graceAfterSend = Duration(seconds: 6);

/// A chat nobody is watching, or one with nothing happening in it.
///
/// The live state itself is [MobileLiveTurn], the shape the computer sends:
/// the answer so far, the steps behind it, and the question the agent is
/// waiting on. A value rather than a void watcher, so the screen draws the
/// trailing turn from it and the composer reads `busy` from the same poll.
const MobileLiveTurn kQuietTurn = MobileLiveTurn(total: 0, busy: false);

/// Watches one chat while its screen is open.
///
/// Holds the turn count it last saw. Only a *change* re-reads the page, so the
/// common answer — nothing happened — costs one tiny request and no redraw.
///
/// `autoDispose`, and that is the "while its screen is open" above: Riverpod 3
/// keeps a plain family alive for the life of the app, so every chat ever
/// opened kept its timer and went on asking the computer about itself every
/// three seconds after its screen had closed.
final chatWatchProvider = NotifierProvider.autoDispose
    .family<ChatWatch, MobileLiveTurn, String>(ChatWatch.new);

/// Polls one chat's head and re-reads the transcript when it moves.
class ChatWatch extends Notifier<MobileLiveTurn> {
  ChatWatch(this.chatId);

  /// The conversation being watched — the family argument.
  final String chatId;

  Timer? _timer;
  Duration? _rate;
  int? _lastTotal;
  String? _lastHead;
  bool _asking = false;

  /// Until when to keep asking fast after a send, busy or not.
  DateTime _fastUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  MobileLiveTurn build() {
    _schedule(_askEvery);
    ref.onDispose(() => _timer?.cancel());
    return kQuietTurn;
  }

  /// Something was just sent: look now, and keep looking fast.
  ///
  /// Without it the first sign of an answer waited for the slow timer — up to
  /// three seconds of a composer that looked like nothing had happened.
  void poke() {
    _fastUntil = DateTime.now().add(_graceAfterSend);
    _schedule(_askWhileWriting);
    unawaited(_ask());
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
    // Nothing to ask through while the link is being put back: the banner
    // already says so, and a poll here would only queue behind the redial.
    if (ref.read(phoneLinkProvider) is! PhoneLinkConnected) return;
    _asking = true;
    try {
      final head = await ref.read(phoneLinkProvider.notifier).call(
        'chats.head',
        {'id': chatId},
      );
      final live = MobileLiveTurn.fromJson(head);
      if (live == null) return;
      final eager = live.busy || DateTime.now().isBefore(_fastUntil);
      _schedule(eager ? _askWhileWriting : _askEvery);

      // Compared as the answer arrived, since the live turn is a tree of
      // steps and a question: an unchanged head — the common case — must not
      // redraw the transcript under somebody's thumb every 700ms.
      final said = jsonEncode(head);
      if (said != _lastHead) {
        _lastHead = said;
        state = live;
      }
      final total = live.total;
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
