import 'dart:math' as math;

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
/// The Telegram chat is in the id so a permission request raised in the Grid
/// chat can be sent back to the right phone without a lookup; the start time
/// is what lets `/new` begin another one.
String telegramConversationId(int chatId, DateTime startedAt) =>
    '$kTelegramChatPrefix$chatId-${startedAt.microsecondsSinceEpoch}';

/// The Telegram chat a Grid chat id carries on, or null for any other chat.
int? telegramChatOf(String conversationId) {
  if (!conversationId.startsWith(kTelegramChatPrefix)) return null;
  final rest = conversationId.substring(kTelegramChatPrefix.length);
  final dash = rest.lastIndexOf('-');
  if (dash <= 0) return null;
  return int.tryParse(rest.substring(0, dash));
}

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

/// How long to wait before polling again after [failures] failures in a row:
/// two seconds, doubling, never more than a minute.
Duration telegramRetryDelay(int failures) =>
    Duration(seconds: math.min(60, 2 << math.min(failures, 5)));
