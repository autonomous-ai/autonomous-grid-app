/// The few shapes Grid reads off Telegram's Bot API, and how it reads them.
///
/// Lenient on purpose: an update Telegram adds a field to, or one Grid has no
/// use for, must read as something to skip rather than an exception that stops
/// the bot answering everyone. Pure, so the reading is tested rather than
/// discovered on a phone.
library;

/// Who the bot is, from `getMe` — [username] is what a person searches for.
typedef TelegramBotIdentity = ({int id, String username, String name});

/// One button under a message. [data] comes back verbatim when it is tapped,
/// and Telegram caps it at 64 bytes.
typedef TelegramButton = ({String label, String data});

/// The buttons under a message, row by row.
typedef TelegramKeyboard = List<List<TelegramButton>>;

/// One entry from `getUpdates`, reduced to what the bot acts on.
sealed class TelegramUpdate {
  const TelegramUpdate(this.updateId);

  /// Telegram's running number; confirming it (offset + 1) is what stops the
  /// same update arriving again.
  final int updateId;
}

/// A text message someone sent the bot.
final class TelegramText extends TelegramUpdate {
  const TelegramText({
    required int updateId,
    required this.chatId,
    required this.privateChat,
    required this.fromId,
    required this.fromName,
    required this.text,
    required this.sentAt,
  }) : super(updateId);

  final int chatId;

  /// A one-to-one chat with the bot, as opposed to a group it was added to.
  final bool privateChat;
  final int fromId;

  /// The sender's first name, or their username when they set none.
  final String fromName;
  final String text;
  final DateTime sentAt;
}

/// A message with nothing Grid can hand the assistant: a photo, a voice note,
/// a sticker. Kept apart from [TelegramIgnored] so the sender can be told.
final class TelegramOtherMessage extends TelegramUpdate {
  const TelegramOtherMessage({
    required int updateId,
    required this.chatId,
    required this.privateChat,
    required this.fromId,
  }) : super(updateId);

  final int chatId;
  final bool privateChat;
  final int fromId;
}

/// A tap on one of the bot's buttons.
final class TelegramButtonPress extends TelegramUpdate {
  const TelegramButtonPress({
    required int updateId,
    required this.callbackId,
    required this.fromId,
    required this.chatId,
    required this.messageId,
    required this.data,
  }) : super(updateId);

  /// Answered so the button stops spinning on the phone.
  final String callbackId;
  final int fromId;
  final int chatId;
  final int messageId;
  final String data;
}

/// Anything else — an edited message, a channel post, someone joining a group.
final class TelegramIgnored extends TelegramUpdate {
  const TelegramIgnored(super.updateId);
}

/// The updates in a `getUpdates` result, dropping entries with no id.
List<TelegramUpdate> parseTelegramUpdates(Object? result) => [
  if (result is List)
    for (final raw in result) ?parseTelegramUpdate(raw),
];

/// One update, or null when it carries no `update_id` to confirm.
TelegramUpdate? parseTelegramUpdate(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['update_id'];
  if (id is! int) return null;
  final message = raw['message'];
  if (message is Map) return _message(id, message);
  final callback = raw['callback_query'];
  if (callback is Map) return _buttonPress(id, callback) ?? TelegramIgnored(id);
  return TelegramIgnored(id);
}

/// Who the bot is, or null when `getMe` answered something unreadable.
TelegramBotIdentity? parseTelegramIdentity(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  final username = raw['username'];
  if (id is! int || username is! String) return null;
  final name = raw['first_name'];
  return (id: id, username: username, name: name is String ? name : username);
}

/// [rows] as Telegram's `inline_keyboard`.
Map<String, Object?> telegramKeyboard(TelegramKeyboard rows) => {
  'inline_keyboard': [
    for (final row in rows)
      [
        for (final button in row)
          {'text': button.label, 'callback_data': button.data},
      ],
  ],
};

TelegramUpdate _message(int updateId, Map<Object?, Object?> message) {
  final chat = message['chat'];
  final from = message['from'];
  if (chat is! Map || from is! Map) return TelegramIgnored(updateId);
  final chatId = chat['id'];
  final fromId = from['id'];
  if (chatId is! int || fromId is! int) return TelegramIgnored(updateId);
  final privateChat = chat['type'] == 'private';
  final text = message['text'];
  if (text is! String || text.trim().isEmpty) {
    return TelegramOtherMessage(
      updateId: updateId,
      chatId: chatId,
      privateChat: privateChat,
      fromId: fromId,
    );
  }
  final date = message['date'];
  return TelegramText(
    updateId: updateId,
    chatId: chatId,
    privateChat: privateChat,
    fromId: fromId,
    fromName: _nameOf(from),
    text: text,
    sentAt: date is int
        ? DateTime.fromMillisecondsSinceEpoch(date * 1000)
        : DateTime.now(),
  );
}

TelegramButtonPress? _buttonPress(int updateId, Map<Object?, Object?> raw) {
  final id = raw['id'];
  final from = raw['from'];
  final message = raw['message'];
  final data = raw['data'];
  if (id is! String || from is! Map || message is! Map || data is! String) {
    return null;
  }
  final chat = message['chat'];
  final fromId = from['id'];
  final messageId = message['message_id'];
  final chatId = chat is Map ? chat['id'] : null;
  if (fromId is! int || messageId is! int || chatId is! int) return null;
  return TelegramButtonPress(
    updateId: updateId,
    callbackId: id,
    fromId: fromId,
    chatId: chatId,
    messageId: messageId,
    data: data,
  );
}

String _nameOf(Map<Object?, Object?> from) {
  final first = from['first_name'];
  if (first is String && first.trim().isNotEmpty) return first.trim();
  final username = from['username'];
  if (username is String && username.trim().isNotEmpty) return username.trim();
  return 'Telegram';
}
