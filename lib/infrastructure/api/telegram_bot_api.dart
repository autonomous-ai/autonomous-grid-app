import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telegram_wire.dart';

/// Why a Bot API call didn't go through.
///
/// **Never carries the request URL.** Telegram puts the bot token in the path
/// (`/bot<token>/getUpdates`), and `dart:io` errors print the URI they failed
/// on — so every error is rebuilt here from its message alone, and nothing a
/// caller logs or shows can leak the token.
sealed class TelegramFailure implements Exception {
  const TelegramFailure();

  String get message;

  @override
  String toString() => message;
}

/// Telegram answered, and the answer was no.
final class TelegramRefused extends TelegramFailure {
  const TelegramRefused(this.status, this.description, {this.retryAfter});

  final int status;

  /// Telegram's own reason — safe to log: it never repeats the token.
  final String description;

  /// How long Telegram asked us to wait before trying again (429), if it said.
  final Duration? retryAfter;

  /// The token is wrong, or @BotFather revoked it.
  bool get badToken => status == 401 || status == 404;

  /// Something else takes this bot's updates: another program polling the same
  /// token, or a webhook pointing somewhere else.
  bool get conflict => status == 409;

  /// The conflict is a webhook rather than another poller.
  bool get webhookSet =>
      conflict && description.toLowerCase().contains('webhook');

  /// The formatted text didn't parse — resend it plain.
  bool get badMarkup =>
      status == 400 && description.toLowerCase().contains('parse entities');

  /// An edit that would leave the message exactly as it is — a menu redrawn
  /// with nothing changed, which is not a failure.
  bool get notModified =>
      status == 400 && description.toLowerCase().contains('not modified');

  @override
  String get message => description;
}

/// Telegram couldn't be reached — no network, a timeout, a broken reply.
final class TelegramUnreachable extends TelegramFailure {
  const TelegramUnreachable(this.message);

  @override
  final String message;
}

/// The part of Telegram's Bot API the in-app bot uses. A seam so the bot's
/// logic runs against a fake in tests, never against Telegram.
abstract interface class TelegramBotApi {
  Future<TelegramBotIdentity> getMe();

  /// Updates after [offset], held open by Telegram for up to
  /// [HttpTelegramBotApi.pollWait] when there are none (long polling).
  Future<List<TelegramUpdate>> getUpdates({int? offset});

  /// Returns the new message's id. [html] sends it as Telegram's HTML subset.
  Future<int> sendMessage(
    int chatId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  });

  /// Replace a message's text and buttons — how a menu moves from screen to
  /// screen in place. No [rows] takes the buttons off.
  Future<void> editMessage(
    int chatId,
    int messageId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  });

  /// "typing…" under the bot's name, for about five seconds.
  Future<void> sendTyping(int chatId);

  /// Stop a tapped button spinning, optionally with a one-line toast.
  Future<void> answerButton(String callbackId, {String? text});

  /// The menu Telegram shows when someone types `/`.
  Future<void> setCommands(Map<String, String> commands);

  /// Telegram refuses long polling while a webhook is set.
  Future<void> deleteWebhook();

  /// Abort whatever is in flight — how a long poll is cut short on stop.
  void close();
}

/// [TelegramBotApi] over `dart:io` HTTPS.
class HttpTelegramBotApi implements TelegramBotApi {
  HttpTelegramBotApi(this._token, {HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final String _token;
  final HttpClient _client;

  /// How long Telegram holds a `getUpdates` open with nothing to say. Long
  /// enough that an idle bot costs two requests a minute, short enough that a
  /// dead connection is noticed within one.
  static const Duration pollWait = Duration(seconds: 30);

  /// Any other call. A message that takes longer than this is better retried
  /// than waited on.
  static const Duration _callTimeout = Duration(seconds: 20);

  @override
  Future<TelegramBotIdentity> getMe() async {
    final identity = parseTelegramIdentity(await _call('getMe', const {}));
    if (identity != null) return identity;
    throw const TelegramUnreachable(
      "Telegram's answer about the bot was unreadable.",
    );
  }

  @override
  Future<List<TelegramUpdate>> getUpdates({int? offset}) async {
    final result = await _call('getUpdates', {
      'offset': ?offset,
      'timeout': pollWait.inSeconds,
      'allowed_updates': const ['message', 'callback_query'],
    }, timeout: pollWait + const Duration(seconds: 15));
    return parseTelegramUpdates(result);
  }

  @override
  Future<int> sendMessage(
    int chatId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  }) async {
    final result = await _call('sendMessage', {
      'chat_id': chatId,
      'text': text,
      ..._format(html: html, rows: rows),
    });
    final id = result is Map ? result['message_id'] : null;
    return id is int ? id : 0;
  }

  @override
  Future<void> editMessage(
    int chatId,
    int messageId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  }) => _call('editMessageText', {
    'chat_id': chatId,
    'message_id': messageId,
    'text': text,
    ..._format(html: html, rows: rows),
  });

  /// What a sent or edited message carries besides its words.
  Map<String, Object?> _format({
    required bool html,
    required TelegramKeyboard rows,
  }) => {
    if (html) 'parse_mode': 'HTML',
    'link_preview_options': const {'is_disabled': true},
    if (rows.isNotEmpty) 'reply_markup': telegramKeyboard(rows),
  };

  @override
  Future<void> sendTyping(int chatId) =>
      _call('sendChatAction', {'chat_id': chatId, 'action': 'typing'});

  @override
  Future<void> answerButton(String callbackId, {String? text}) => _call(
    'answerCallbackQuery',
    {'callback_query_id': callbackId, 'text': ?text},
  );

  @override
  Future<void> setCommands(Map<String, String> commands) =>
      _call('setMyCommands', {
        'commands': [
          for (final entry in commands.entries)
            {'command': entry.key, 'description': entry.value},
        ],
      });

  @override
  Future<void> deleteWebhook() => _call('deleteWebhook', const {});

  @override
  void close() => _client.close(force: true);

  /// POST [method] and hand back its `result`, or throw a [TelegramFailure]
  /// that never names the URL (see [TelegramFailure]).
  Future<Object?> _call(
    String method,
    Map<String, Object?> body, {
    Duration timeout = _callTimeout,
  }) async {
    final Object? decoded;
    try {
      final request = await _client.postUrl(
        Uri.https('api.telegram.org', '/bot$_token/$method'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(timeout);
      decoded = jsonDecode(await response.transform(utf8.decoder).join());
    } on TimeoutException {
      throw const TelegramUnreachable("Telegram didn't answer in time.");
    } on SocketException catch (error) {
      throw TelegramUnreachable(
        "Can't reach Telegram: ${error.osError?.message ?? error.message}",
      );
    } on HttpException catch (error) {
      throw TelegramUnreachable("Can't reach Telegram: ${error.message}");
    } on TlsException catch (error) {
      throw TelegramUnreachable("Can't reach Telegram: ${error.message}");
    } on FormatException {
      throw const TelegramUnreachable("Telegram's answer was unreadable.");
    }
    return _resultOf(decoded);
  }
}

/// The `result` of an `ok` answer, or the refusal an error answer carries.
Object? _resultOf(Object? decoded) {
  if (decoded is! Map) {
    throw const TelegramUnreachable("Telegram's answer was unreadable.");
  }
  if (decoded['ok'] == true) return decoded['result'];
  final status = decoded['error_code'];
  final description = decoded['description'];
  final parameters = decoded['parameters'];
  final retry = parameters is Map ? parameters['retry_after'] : null;
  throw TelegramRefused(
    status is int ? status : 0,
    description is String ? description : 'Telegram refused the request.',
    retryAfter: retry is int ? Duration(seconds: retry) : null,
  );
}
