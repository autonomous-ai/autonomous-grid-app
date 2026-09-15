import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../playground/logic/chat_message.dart';
import 'telegram_markup.dart';

/// How often the answer on the phone is brought up to date while it is being
/// written.
///
/// Not every token: Telegram rate-limits edits per chat, and a message that
/// reflows on every word is unreadable on a phone. dev-quen-bots settled on the
/// same one and a half seconds.
const Duration kTelegramStreamEvery = Duration(milliseconds: 1500);

/// One message of the answer that has to be drawn or redrawn.
typedef TelegramStreamEdit = ({int index, TelegramChunk chunk, bool fresh});

/// What a flush has to change: the messages not sent yet, and the ones whose
/// text has moved on since they were last drawn.
///
/// [shown] is what each message says now. Pure, so the rule that decides how
/// many edits an answer costs is tested rather than watched on a phone.
List<TelegramStreamEdit> telegramStreamEdits(
  List<String> shown,
  List<TelegramChunk> chunks,
) => [
  for (var i = 0; i < chunks.length; i++)
    if (i >= shown.length)
      (index: i, chunk: chunks[i], fresh: true)
    else if (shown[i] != chunks[i].text)
      (index: i, chunk: chunks[i], fresh: false),
];

/// Puts the assistant's answer on the phone **as it is written** — one Telegram
/// message per chunk, edited in place until the turn lands.
///
/// Reads the same live text the window's transcript draws
/// ([SendStreaming.text], the whole answer so far), so the phone and the
/// computer are never showing two different answers.
class TelegramStream {
  TelegramStream(
    this._ref,
    this._api, {
    required this.chatId,
    required this.conversationId,
    required AppLog log,
  }) : _log = log;

  final Ref _ref;
  final TelegramBotApi _api;

  /// The Telegram chat the answer is being written into.
  final int chatId;

  /// The Grid chat being answered.
  final String conversationId;

  final AppLog _log;

  /// Telegram's ids for the messages this turn has sent, and what each says.
  final List<int> _sent = [];
  final List<String> _shown = [];

  /// How many of the chat's assistant messages this stream has delivered, so
  /// the reply that follows doesn't send them a second time.
  int delivered = 0;

  /// How much the chat had already said when this turn started — everything
  /// before it is history, and belongs to nobody's phone.
  int _before = 0;

  String _latest = '';

  /// The draws so far, in order — one at a time, so the last word in never
  /// loses to a slower flush that started before it.
  Future<void> _drawing = Future<void>.value();

  /// The landing in progress, if any: [close] waits for it, or the answer it
  /// is drawing would be sent a second time as an ordinary reply.
  Future<void> _landing = Future<void>.value();

  Timer? _timer;
  ProviderSubscription<SendPhase>? _phases;

  /// Follow the turn in [conversationId] until [close].
  void listen() {
    _before = _answers().length;
    _phases = _ref.listen<SendPhase>(
      chatSessionsProvider.select((chats) => chats.phaseFor(conversationId)),
      (_, phase) => _onPhase(phase),
    );
  }

  /// Stop following, after drawing whatever is left.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _phases?.close();
    _phases = null;
    await _landing;
    if (_latest.isNotEmpty) await _flush();
  }

  void _onPhase(SendPhase phase) {
    switch (phase) {
      case SendStreaming(:final text):
        _latest = text;
        _schedule();
      case SendIdle():
        // One landing after another: a carry-on turn's answer must not be
        // drawn before the answer it carries on from.
        _landing = _landing.then((_) => _land());
      default:
        return;
    }
  }

  /// Redraw soon, not now: the next token is milliseconds away.
  void _schedule() {
    if (_timer != null) return;
    _timer = Timer(kTelegramStreamEvery, () {
      _timer = null;
      unawaited(_flush());
    });
  }

  /// The turn landed (or was stopped): draw the answer as the transcript kept
  /// it — the whole thing, formatted — and start fresh for the next turn.
  Future<void> _land() async {
    _timer?.cancel();
    _timer = null;
    final answers = _answers();
    final landed = _before + delivered;
    if (answers.length > landed) {
      _latest = answers[landed];
      await _flush();
      delivered++;
    }
    _sent.clear();
    _shown.clear();
    _latest = '';
  }

  /// Bring the phone up to date with [_latest], behind whatever draw is
  /// already running.
  Future<void> _flush() {
    _drawing = _drawing.then((_) => _drawLatest());
    return _drawing;
  }

  Future<void> _drawLatest() async {
    final text = _latest;
    if (text.trim().isEmpty) return;
    try {
      for (final edit in telegramStreamEdits(_shown, telegramChunks(text))) {
        await _draw(edit);
      }
    } on Object catch (error) {
      _log.warn('telegram', "couldn't draw the answer as it arrived: $error");
    }
  }

  Future<void> _draw(TelegramStreamEdit edit) async {
    final chunk = edit.chunk;
    if (edit.fresh) {
      _sent.add(await _send(chunk));
      _shown.add(chunk.text);
      return;
    }
    await _edit(_sent[edit.index], chunk);
    _shown[edit.index] = chunk.text;
  }

  Future<int> _send(TelegramChunk chunk) async {
    try {
      return await _api.sendMessage(chatId, chunk.text, html: chunk.html);
    } on TelegramRefused catch (error) {
      if (!chunk.html || !error.badMarkup) rethrow;
      return _api.sendMessage(chatId, telegramPlainText(chunk.text));
    }
  }

  Future<void> _edit(int messageId, TelegramChunk chunk) async {
    try {
      await _api.editMessage(chatId, messageId, chunk.text, html: chunk.html);
    } on TelegramRefused catch (error) {
      if (error.notModified) return;
      if (chunk.html && error.badMarkup) {
        await _api.editMessage(
          chatId,
          messageId,
          telegramPlainText(chunk.text),
        );
        return;
      }
      // Too fast for Telegram: the next flush carries the same text anyway.
      if (error.retryAfter == null) rethrow;
    }
  }

  /// Everything the assistant has said in this chat, oldest first.
  List<String> _answers() {
    for (final chat in _ref.read(chatSessionsProvider).conversations) {
      if (chat.id != conversationId) continue;
      return [
        for (final message in chat.messages)
          if (message.role == ChatRole.assistant &&
              message.text.trim().isNotEmpty)
            message.text.trim(),
      ];
    }
    return const [];
  }
}
