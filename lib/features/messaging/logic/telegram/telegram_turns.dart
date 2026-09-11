import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../chat/logic/chat_settled.dart';
import '../../../chat/logic/turn_model.dart';
import '../../../playground/logic/playground_models.dart';
import 'telegram_markup.dart';
import 'telegram_rules.dart';

/// The Grid chat Telegram chat `chatId` is carrying on — a new one when there
/// is none yet, or when [fresh] asks for one.
typedef TelegramThreadFor = Future<String> Function(int chatId, {bool fresh});

/// [work], with a failure logged rather than thrown: a lost "typing…" or a
/// courtesy note must not take down the turn it decorates.
Future<void> telegramQuietly(AppLog log, Future<void> work) async {
  try {
    await work;
  } on Object catch (error) {
    log.warn('telegram', "couldn't reach Telegram: $error");
  }
}

/// Turns a Telegram message into a turn in a Grid chat, and the answer back
/// into Telegram messages.
///
/// Through [chatSessionsProvider] rather than beside it, like the Grid Panel:
/// the chat is one the window shows, so the conversation is in Chat's history,
/// keeps its context, and is answered by the same assistant and model the user
/// picked there — not a second, lesser copy of the Chat tab.
class TelegramTurns {
  TelegramTurns(this._ref, this._api, {required this.threadFor});

  final Ref _ref;
  final TelegramBotApi _api;
  final TelegramThreadFor threadFor;

  /// The tail of each Telegram chat's queue: one message at a time, in order.
  final Map<int, Future<void>> _queue = {};

  /// Bumped by [stop], so messages queued behind the stopped one are dropped.
  final Map<int, int> _generation = {};

  AppLog get _log => _ref.read(appLogProvider);

  /// Answer [message] after whatever this chat is already answering.
  void ask(TelegramText message) {
    final chatId = message.chatId;
    if (_queue.containsKey(chatId)) {
      note(chatId, 'Still on your last message — this one is next.');
    }
    final generation = _generation[chatId] ?? 0;
    final next = (_queue[chatId] ?? Future<void>.value()).then((_) async {
      if ((_generation[chatId] ?? 0) != generation) return;
      await _guarded(message);
    });
    _queue[chatId] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_queue[chatId], next)) _queue.remove(chatId);
      }),
    );
  }

  /// Stop the answer being written in [conversationId], and drop whatever
  /// Telegram chat [chatId] had queued behind it — Stop means stop.
  void stop(int chatId, String? conversationId) {
    _generation[chatId] = (_generation[chatId] ?? 0) + 1;
    if (conversationId == null) return;
    _ref.read(chatSessionsProvider.notifier).stopChat(conversationId);
  }

  /// Send [markdown] to [chatId] without waiting, a failure only logged.
  void note(int chatId, String markdown) =>
      unawaited(telegramQuietly(_log, reply(chatId, markdown)));

  /// Send [markdown] to [chatId], in as many messages as it takes.
  Future<void> reply(int chatId, String markdown) async {
    for (final chunk in telegramChunks(markdown)) {
      try {
        await _api.sendMessage(chatId, chunk.text, html: chunk.html);
      } on TelegramRefused catch (error) {
        if (!chunk.html || !error.badMarkup) rethrow;
        await _api.sendMessage(chatId, telegramPlainText(chunk.text));
      }
    }
  }

  Future<void> _guarded(TelegramText message) async {
    try {
      await _answer(message);
    } on Object catch (error, stack) {
      _log.failure(
        'telegram',
        'a Telegram message went unanswered',
        error: error,
        stackTrace: stack,
      );
      note(
        message.chatId,
        "Something went wrong on the computer, so this didn't get an answer. "
        'Try sending it again.',
      );
    }
  }

  Future<void> _answer(TelegramText message) async {
    final sessions = _ref.read(chatSessionsProvider.notifier);
    await sessions.restored;
    final network = _ref.read(selectedNetworkProvider);
    if (network == null) {
      return reply(
        message.chatId,
        "Grid isn't on a grid right now, so there is nothing to answer with. "
        'Open Grid on your computer and pick one.',
      );
    }
    final prefs = _ref.read(chatPrefsProvider);
    final chat = sessions.ensureBackgroundChat(
      id: await threadFor(message.chatId),
      title: 'Telegram · ${message.fromName}',
      approval: telegramApprovalMode(prefs.approval),
    );
    final model = firstModelChoice([
      chat.model,
      prefs.model,
      _ref.read(playgroundModelsProvider).firstOrNull?.id,
    ]);
    if (model.isEmpty) {
      return reply(
        message.chatId,
        'No model is running on this grid right now. Start one in Grid, then '
        'send this again.',
      );
    }
    // Someone may be typing in this chat on the computer; their turn first.
    await chatSettled(_ref, chat.id);
    final before = _answersIn(chat.id).length;
    final typing = _typing(message.chatId);
    try {
      await sessions.send(
        network: network,
        model: model,
        message: message.text,
        into: chat.id,
      );
      await chatSettled(_ref, chat.id);
    } finally {
      typing.cancel();
    }
    await _report(message.chatId, chat.id, before);
  }

  /// What the assistant said since [before], then why it stopped short if it
  /// did. Read from the transcript, because the transcript is the record.
  Future<void> _report(int chatId, String id, int before) async {
    final answers = _answersIn(id).skip(before).toList();
    for (final answer in answers) {
      await reply(chatId, answer);
    }
    final error = _ref.read(chatSessionsProvider).errorFor(id);
    if (error != null) return reply(chatId, "Couldn't finish: $error");
    if (answers.isEmpty) await reply(chatId, 'Stopped before it answered.');
  }

  /// Every non-empty thing the assistant said in chat [id], oldest first.
  List<String> _answersIn(String id) {
    for (final chat in _ref.read(chatSessionsProvider).conversations) {
      if (chat.id != id) continue;
      return [
        for (final message in chat.messages)
          if (message.role == ChatRole.assistant &&
              message.text.trim().isNotEmpty)
            message.text.trim(),
      ];
    }
    return const [];
  }

  /// "typing…" under the bot's name for as long as the answer takes — it
  /// lapses after five seconds, so it is renewed every four.
  Timer _typing(int chatId) {
    void beat() => unawaited(telegramQuietly(_log, _api.sendTyping(chatId)));
    beat();
    return Timer.periodic(const Duration(seconds: 4), (_) => beat());
  }
}
