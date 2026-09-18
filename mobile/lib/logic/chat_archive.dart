/// Putting a chat away, and taking it back out.
///
/// Its own file rather than another branch of the option pills: archiving is
/// not a property of the next turn, it is what happens to the conversation —
/// and it is reached by a swipe, not by a picker.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_chat_options.dart';

/// Archives [chatId], or puts it back when [away] is false.
///
/// Returns null when it worked, or the computer's own sentence when it did not
/// — it is the side that knows whether the chat is mid-answer.
///
/// Goes through `chats.set` rather than a method of its own: it is one more
/// thing about a chat that the computer changes, and every one of those is
/// behind the same switch.
Future<String?> archiveChat(
  WidgetRef ref, {
  required String chatId,
  required bool away,
}) => pickChatOption(
  ref,
  chatId: chatId,
  field: 'archived',
  value: away ? 'true' : 'false',
);
