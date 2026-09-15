/// Sending a message from the phone, and waiting for the answer to land.
///
/// Its own controller rather than state inside the chat screen, because it is
/// not one call: the computer accepts the turn in milliseconds and then spends
/// tens of seconds answering it, so "sent" and "answered" are different moments
/// and the screen has to show both.
///
/// The waiting is polling, and deliberately so. The channel could push, but the
/// desktop's reply frames are correlated to requests by id and teaching both
/// ends to carry unsolicited frames is a protocol change; asking again every
/// [_pollEvery] costs one small request and cannot desynchronise anything.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_attachments.dart';
import 'phone_chats.dart';
import 'phone_uploads.dart';
import 'phone_link_controller.dart';
import 'relay_phone_client.dart';

/// How often the phone re-reads a chat while an answer is being written.
const Duration _pollEvery = Duration(milliseconds: 1500);

/// When to stop waiting, however the computer is getting on.
///
/// An agent turn can legitimately run for minutes. This is not a timeout on the
/// work — the computer carries on regardless — it is the point at which the
/// phone stops holding a spinner and lets the person pull to refresh, because a
/// spinner that never ends is indistinguishable from a broken app.
const Duration _giveUpAfter = Duration(minutes: 5);

/// Where a send has got to.
sealed class PhoneSendState {
  const PhoneSendState();
}

/// Nothing in flight.
final class PhoneSendIdle extends PhoneSendState {
  const PhoneSendIdle();
}

/// On its way, or being answered.
final class PhoneSendWorking extends PhoneSendState {
  const PhoneSendWorking();
}

/// It did not go, and this says why in words the person can act on.
final class PhoneSendFailed extends PhoneSendState {
  const PhoneSendFailed(this.message);

  /// Shown as-is.
  final String message;
}

/// Sends into one chat.
final phoneSendProvider =
    NotifierProvider.family<PhoneSendController, PhoneSendState, String>(
      PhoneSendController.new,
    );

/// Puts a message into a chat on the computer and watches for the answer.
class PhoneSendController extends Notifier<PhoneSendState> {
  PhoneSendController(this.chatId);

  /// The conversation this sends into — the family argument, and what keeps one
  /// chat's spinner off another chat's screen.
  final String chatId;

  Timer? _poll;

  @override
  PhoneSendState build() {
    ref.onDispose(() => _poll?.cancel());
    return const PhoneSendIdle();
  }

  /// Sends [text] with whatever is attached, then waits for the answer.
  ///
  /// [uploadEach] does the actual putting-on-the-computer. It is passed in
  /// because it needs a [WidgetRef] and this is a notifier — and because it
  /// keeps the part that can take a minute over a phone connection out of the
  /// state machine that has to stay readable.
  Future<void> send(
    String text, {
    required Future<List<String>> Function(List<OutgoingFile>) uploadEach,
  }) async {
    final staged = ref.read(attachmentsProvider(chatId));
    if (text.trim().isEmpty && staged.isEmpty) return;
    state = const PhoneSendWorking();
    try {
      // Files first: the message names them, so a send that went before them
      // would arrive asking about pictures that are not there yet.
      final uploads = await uploadEach(staged);
      await ref.read(phoneLinkProvider.notifier).call('chats.send', {
        'id': chatId,
        'text': text.trim(),
        if (uploads.isNotEmpty) 'uploads': uploads,
      });
      ref.read(attachmentsProvider(chatId).notifier).clear();
    } on RelayPhoneFailure catch (failure) {
      state = PhoneSendFailed(failure.message);
      return;
    }
    // Show the question in the transcript straight away. It is already on the
    // computer by now, so this is not optimism — it is the phone catching up.
    _reread();
    _watchForTheAnswer();
  }

  /// Stops waiting, leaving whatever has arrived on screen.
  void stopWaiting() {
    _poll?.cancel();
    _poll = null;
    state = const PhoneSendIdle();
  }

  void _watchForTheAnswer() {
    _poll?.cancel();
    final startedAt = DateTime.now();
    _poll = Timer.periodic(_pollEvery, (timer) {
      if (DateTime.now().difference(startedAt) > _giveUpAfter) {
        stopWaiting();
        return;
      }
      final page = ref
          .read(transcriptProvider((id: chatId, offset: null)))
          .value;
      // Null while the re-read is in flight — that is a poll that has not
      // answered yet, not an answer that has finished.
      if (page != null && !page.busy) {
        stopWaiting();
        return;
      }
      _reread();
    });
  }

  void _reread() =>
      ref.invalidate(transcriptProvider((id: chatId, offset: null)));
}
