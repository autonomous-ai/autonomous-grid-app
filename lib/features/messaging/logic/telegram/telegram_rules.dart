import 'dart:math' as math;

import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/cli/agent_event.dart';

/// A message older than this when Grid first sees it was sent while Grid was
/// closed.
///
/// It is not run: the sender has long since stopped waiting, and an assistant
/// that can change files acting on a request from yesterday evening — the moment
/// Grid happens to be opened — is a surprise nobody asked for. They are told,
/// and can send it again.
const Duration kTelegramStaleAfter = Duration(minutes: 10);

/// Every Grid chat that carries on a Telegram conversation starts with this.
const String kTelegramChatPrefix = 'telegram-';

/// The commands the bot answers itself, and the line Telegram's `/` menu shows
/// for each. Anything else starting with `/` goes to the assistant as typed,
/// the way the Chat composer forwards it.
const Map<String, String> kTelegramCommandMenu = {
  'new': 'Start a new chat',
  'sessions': 'Browse & switch chats',
  'model': 'View & change model',
  'stop': 'Stop the answer in progress',
};

/// A command the bot handles without the assistant.
enum TelegramCommand {
  /// Telegram sends this the first time someone opens the bot.
  start,

  /// Start a new Grid chat, where the current one is (its project, or none).
  fresh,

  /// Pick a project or the plain chats, then a chat in it to carry on.
  sessions,

  /// See and change the model the current chat answers with.
  model,

  /// Stop the answer being written.
  stop,
}

/// Whether the bot answers a message from [fromId]: only in a one-to-one chat,
/// and only for an id on [allowed].
///
/// Groups are refused even for a listed id — in a group, anyone there can read
/// the answer, and some of them can reply to it.
bool telegramMayAnswer({
  required int fromId,
  required bool privateChat,
  required List<String> allowed,
}) => privateChat && allowed.contains('$fromId');

/// Whether a message sent at [sentAt] is too old to run now — see
/// [kTelegramStaleAfter].
bool telegramMessageIsStale(DateTime sentAt, DateTime now) =>
    now.difference(sentAt) > kTelegramStaleAfter;

/// The bot's own command in [text], or null for anything the assistant should
/// read. `/new@my_bot` (how Telegram writes a command picked from the menu in
/// some clients) is the same command as `/new`.
TelegramCommand? parseTelegramCommand(String text) {
  final first = text.trim().split(RegExp(r'\s+')).first.toLowerCase();
  if (!first.startsWith('/')) return null;
  return switch (first.substring(1).split('@').first) {
    'start' => TelegramCommand.start,
    'new' => TelegramCommand.fresh,
    'sessions' => TelegramCommand.sessions,
    'model' => TelegramCommand.model,
    'stop' => TelegramCommand.stop,
    _ => null,
  };
}

/// What was typed after the command word, trimmed — `/model gpt-5` → `gpt-5`,
/// and `''` for a command on its own.
String telegramCommandArgument(String text) {
  final line = text.trim();
  final space = line.indexOf(RegExp(r'\s'));
  return space < 0 ? '' : line.substring(space + 1).trim();
}

/// The id of a new Grid chat carrying on Telegram chat [chatId].
///
/// The prefix marks it as the bot's rather than something opened in the window,
/// and the start time is what lets `/new` begin another one. Which phone a chat
/// belongs to is *not* read back out of this: `/sessions` points a Telegram chat
/// at a desktop chat whose id carries no prefix at all, so the bot keeps the
/// pairing itself and answers it with `TelegramThreads.chatIdOf`.
String telegramConversationId(int chatId, DateTime startedAt) =>
    '$kTelegramChatPrefix$chatId-${startedAt.microsecondsSinceEpoch}';

/// How much a Telegram chat lets the assistant do, given the app's own mode.
///
/// The same as Chat, except Plan: a planning turn ends waiting on an approval
/// bar that only exists in the window, which a phone can't press — so a
/// Telegram chat asks before each action instead, which it can.
AgentApprovalMode telegramApprovalMode(AgentApprovalMode app) =>
    app == AgentApprovalMode.plan ? AgentApprovalMode.ask : app;

/// What a permission button sends back: which question it answers ([ask]) and
/// the answer. The question number is what makes a button left over from an
/// earlier question do nothing instead of answering the current one.
String telegramAnswerData(int ask, AgentPermissionChoice choice) =>
    'perm:$ask:${choice.name}';

/// The inverse of [telegramAnswerData], or null for data it didn't write.
({int ask, AgentPermissionChoice choice})? parseTelegramAnswerData(
  String data,
) {
  final parts = data.split(':');
  if (parts.length != 3 || parts.first != 'perm') return null;
  final ask = int.tryParse(parts[1]);
  if (ask == null) return null;
  for (final choice in AgentPermissionChoice.values) {
    if (choice.name == parts[2]) return (ask: ask, choice: choice);
  }
  return null;
}

/// The Stop button under an answer as it is being written.
///
/// One button, on the message the answer is currently growing into, so it is
/// at the bottom of the chat where the answer is — reaching for `/stop` on a
/// phone means leaving the answer to find the keyboard.
TelegramKeyboard telegramStopRows(int turn) => [
  [(label: '⏹ Stop', data: 'stop:$turn')],
];

/// Which answer a Stop button was drawn under, or null for other data.
///
/// The *chat* is deliberately not in here: it is read off the tap itself, so a
/// listed user cannot hand-craft a tap that stops an answer running in someone
/// else's chat. The turn number only says *which* answer, and a tap naming one
/// that has since finished is refused rather than stopping whatever replaced it
/// — a button left behind by a clear that never reached Telegram must not stop
/// the next answer instead.
int? parseTelegramStopData(String data) {
  final parts = data.split(':');
  if (parts.length != 2 || parts.first != 'stop') return null;
  return int.tryParse(parts[1]);
}

/// How long to wait before polling again after [failures] failures in a row:
/// two seconds, doubling, never more than a minute.
Duration telegramRetryDelay(int failures) =>
    Duration(seconds: math.min(60, 2 << math.min(failures, 5)));
