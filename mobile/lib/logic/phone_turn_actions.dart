/// The two things the phone can do to an answer while it is being written:
/// stop it, and answer the question the agent stopped to ask.
///
/// Plain functions rather than a controller: neither holds state. What they
/// change is on the computer, and the chat's own poll ([ChatWatch]) is what
/// shows the result — asked at once, so the card or the Stop button goes the
/// moment the computer has acted rather than a poll later.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'chat_watch.dart';
import 'phone_link_controller.dart';
import 'relay_phone_client.dart';

/// Stops the answer being written in [chatId]. Null once it has, or a sentence
/// to show when the computer would not.
Future<String?> stopAnswer(WidgetRef ref, String chatId) =>
    _act(ref, chatId, 'chats.stop', {'id': chatId});

/// Answers question [questionId] in [chatId] with [choice]. Null once the
/// computer has it, or a sentence to show — the question closed, or this phone
/// may only read.
Future<String?> answerQuestion(
  WidgetRef ref, {
  required String chatId,
  required String questionId,
  required MobilePermissionChoice choice,
}) => _act(ref, chatId, 'chats.answer', {
  'id': chatId,
  'question': questionId,
  'choice': choice.name,
});

Future<String?> _act(
  WidgetRef ref,
  String chatId,
  String method,
  Map<String, Object?> params,
) async {
  try {
    await ref.read(phoneLinkProvider.notifier).call(method, params);
    return null;
  } on RelayPhoneFailure catch (failure) {
    return failure.message;
  } finally {
    ref.read(chatWatchProvider(chatId).notifier).poke();
  }
}
