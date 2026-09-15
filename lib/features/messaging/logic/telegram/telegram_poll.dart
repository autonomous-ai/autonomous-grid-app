import 'dart:async';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../messaging_state.dart';
import 'telegram_rules.dart';

/// After this many failed polls in a row, "connecting" stops being honest and
/// the screen says the bot isn't answering, with the reason.
const int _kQuietFailures = 3;

/// Asks Telegram for the bot's messages, over and over, until [stop].
///
/// Long polling rather than a webhook because a webhook needs an address on
/// the public internet, and a laptop behind a home router has none. The poll
/// is also the bot's heartbeat: a poll that came back is the only honest
/// "answering", so the link is reported from here and nowhere else.
class TelegramPoll {
  TelegramPoll(this._api, {required this.onUpdate, required this.onLink});

  final TelegramBotApi _api;

  /// Called for each update, in order. Must not wait on the answer — the next
  /// poll is what confirms these to Telegram, so it has to go out at once.
  final void Function(TelegramUpdate update) onUpdate;

  /// The link as it changes, with the reason when it isn't answering.
  final void Function(MessagingLink link, String? detail) onLink;

  bool _stopped = false;
  Completer<void>? _nap;
  int? _offset;
  int _failures = 0;

  /// Poll until [stop] or until Telegram refuses the token for good.
  Future<void> run() async {
    onLink(MessagingLink.connecting, null);
    while (!_stopped) {
      try {
        final updates = await _api.getUpdates(offset: _offset);
        if (_stopped) return;
        _failures = 0;
        onLink(MessagingLink.answering, null);
        for (final update in updates) {
          _offset = update.updateId + 1;
          onUpdate(update);
        }
      } on TelegramRefused catch (error) {
        if (_stopped) return;
        final wait = await _afterRefusal(error);
        if (wait == null) return;
        await _sleep(wait);
      } on TelegramUnreachable catch (error) {
        if (_stopped) return;
        _reportFailure(
          'Can\'t reach Telegram, so Grid keeps trying. '
          '(${error.message})',
        );
        await _sleep(telegramRetryDelay(_failures));
      }
    }
  }

  /// Stop polling now, cutting short a poll in flight or a wait between polls.
  void stop() {
    _stopped = true;
    _api.close();
    final nap = _nap;
    if (nap != null && !nap.isCompleted) nap.complete();
  }

  /// How long to wait before the next poll, or null to stop for good.
  Future<Duration?> _afterRefusal(TelegramRefused error) async {
    if (error.badToken) {
      onLink(
        MessagingLink.notAnswering,
        'Telegram refused this bot\'s token — it may have been revoked. '
        'Disconnect, then connect again with a new token from @BotFather.',
      );
      return null;
    }
    if (error.webhookSet) {
      // The token was handed to Grid to answer here; a webhook left over from
      // somewhere else would block that for good, so it goes.
      await _api.deleteWebhook().catchError((Object _) {});
      return Duration.zero;
    }
    if (error.conflict) {
      _failures++;
      onLink(
        MessagingLink.notAnswering,
        'Another program is answering as this bot, so Telegram sends it the '
        'messages instead. Stop it there and Grid picks up on its own.',
      );
      return const Duration(seconds: 15);
    }
    _reportFailure('Telegram is having trouble (${error.description}).');
    return error.retryAfter ?? telegramRetryDelay(_failures);
  }

  void _reportFailure(String detail) {
    _failures++;
    if (_failures < _kQuietFailures) {
      onLink(MessagingLink.connecting, null);
      return;
    }
    onLink(MessagingLink.notAnswering, detail);
  }

  Future<void> _sleep(Duration duration) {
    if (duration == Duration.zero || _stopped) return Future.value();
    final nap = _nap = Completer<void>();
    final timer = Timer(duration, () {
      if (!nap.isCompleted) nap.complete();
    });
    return nap.future.whenComplete(timer.cancel);
  }
}
