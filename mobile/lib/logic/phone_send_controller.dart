/// Sending a message from the phone.
///
/// Its own controller rather than state inside the chat screen, because a send
/// is more than one call — the files go up first, a piece at a time, and that
/// can take a minute over a phone connection.
///
/// It stops at "the computer has it". Whether an answer is being written is
/// [ChatWatch]'s to say: it polls the chat's head anyway, and this used to run
/// a second poll beside it that re-read the whole transcript every 1.5 seconds
/// to learn the same one flag.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_watch.dart';
import 'phone_attachments.dart';
import 'phone_chats.dart';
import 'phone_link_controller.dart';
import 'phone_uploads.dart';
import 'relay_phone_client.dart';

/// Where a send has got to.
sealed class PhoneSendState {
  const PhoneSendState();
}

/// Nothing in flight.
final class PhoneSendIdle extends PhoneSendState {
  const PhoneSendIdle();
}

/// On its way to the computer — files uploading, or the message itself.
final class PhoneSendSending extends PhoneSendState {
  const PhoneSendSending();
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

/// Puts a message into a chat on the computer.
class PhoneSendController extends Notifier<PhoneSendState> {
  PhoneSendController(this.chatId);

  /// The conversation this sends into — the family argument, and what keeps one
  /// chat's spinner off another chat's screen.
  final String chatId;

  @override
  PhoneSendState build() => const PhoneSendIdle();

  /// Sends [text] with whatever is attached.
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
    state = const PhoneSendSending();
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
    state = const PhoneSendIdle();
    // Show the question in the transcript straight away — it is already on the
    // computer, so this is not optimism, it is the phone catching up — and
    // start watching for the answer at the fast rate.
    ref.invalidate(transcriptProvider((id: chatId, offset: null)));
    ref.read(chatWatchProvider(chatId).notifier).poke();
  }
}
