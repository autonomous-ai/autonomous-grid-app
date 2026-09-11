import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../agents/logic/agent_permissions.dart';
import '../messaging_platform.dart';
import '../messaging_state.dart';
import 'telegram_bot_store.dart';
import 'telegram_permission_relay.dart';
import 'telegram_poll.dart';
import 'telegram_rules.dart';
import 'telegram_turns.dart';

const String _kGreeting =
    "Hi! I'm Grid, answering from your computer. Send a message and the "
    'assistant there replies.\n\n/new starts a fresh conversation, /stop stops '
    'an answer.';

/// The Telegram bot Grid answers as, in the app itself.
sealed class TelegramBotState {
  const TelegramBotState();
}

/// The saved bot hasn't been read yet — the first moment after launch.
final class TelegramBotLoading extends TelegramBotState {
  const TelegramBotLoading();
}

/// No bot is connected.
final class TelegramBotOff extends TelegramBotState {
  const TelegramBotOff();
}

/// A bot is connected; [link] says whether it is really answering, and
/// [detail] why not when it isn't.
final class TelegramBotOn extends TelegramBotState {
  const TelegramBotOn({required this.config, required this.link, this.detail});

  final TelegramBotConfig config;
  final MessagingLink link;
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is TelegramBotOn &&
      other.config == config &&
      other.link == link &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(config, link, detail);
}

/// Makes the Bot API client for a token. Overridable so tests hand the bot a
/// fake and never reach Telegram.
final telegramBotApiProvider = Provider<TelegramBotApi Function(String token)>(
  (ref) => HttpTelegramBotApi.new,
);

/// The in-app Telegram bot: connect, run while Grid is open, disconnect.
///
/// Needs a real listener to hear the permission requests it relays (Riverpod
/// pauses a provider nobody listens to) — `TelegramBotScope` is that listener,
/// for the life of the app.
final telegramBotProvider =
    NotifierProvider<TelegramBotController, TelegramBotState>(
      TelegramBotController.new,
    );

class TelegramBotController extends Notifier<TelegramBotState> {
  TelegramPoll? _poll;
  TelegramTurns? _turns;
  TelegramPermissionRelay? _relay;

  /// Ids already logged as not on the list, so a stranger's every message
  /// doesn't add a line.
  final Set<int> _strangers = {};

  AppLog get _log => ref.read(appLogProvider);
  TelegramBotStore get _store => ref.read(telegramBotStoreProvider);

  @override
  TelegramBotState build() {
    ref.listen(
      agentPermissionsProvider,
      (_, open) => _relay?.onPermissions(open),
    );
    ref.onDispose(_stop);
    return const TelegramBotLoading();
  }

  /// Start answering as the saved bot, if there is one — once, as Grid opens.
  Future<void> resume() async {
    final config = await _store.read();
    if (config == null) {
      state = const TelegramBotOff();
      return;
    }
    _start(config);
  }

  /// Check [token] with Telegram, save the bot, and start answering [userId].
  /// Null on success, else the line to show.
  Future<String?> connect({
    required String token,
    required String userId,
  }) async {
    final invalid = validateTelegramToken(token) ?? validateTelegramId(userId);
    if (invalid != null) return invalid;
    final api = ref.read(telegramBotApiProvider)(token.trim());
    final TelegramBotIdentity identity;
    try {
      identity = await api.getMe();
    } on TelegramFailure catch (error) {
      api.close();
      return _connectError(error);
    }
    final config = TelegramBotConfig(
      token: token.trim(),
      allowedUsers: List.unmodifiable([userId.trim()]),
      botName: identity.username,
    );
    await _store.write(config);
    _log.info('telegram', 'connected @${identity.username}, answering in Grid');
    _start(config, api);
    unawaited(telegramQuietly(_log, api.setCommands(kTelegramCommandMenu)));
    return null;
  }

  /// Stop answering and forget the bot.
  Future<void> disconnect() async {
    _stop();
    await _store.delete();
    state = const TelegramBotOff();
    _log.info('telegram', 'disconnected the bot');
  }

  /// Stop and start again from what is saved — the "Turn it on" button.
  Future<void> restart() async {
    _stop();
    await resume();
  }

  String _connectError(TelegramFailure error) => switch (error) {
    TelegramRefused(badToken: true) =>
      "Telegram didn't accept that token. Copy it again from @BotFather — the "
          'whole line.',
    TelegramRefused(:final description) =>
      'Telegram refused the bot: $description',
    TelegramUnreachable() =>
      "Couldn't reach Telegram to check the token. Check this computer's "
          'internet connection, then try again.',
  };

  void _start(TelegramBotConfig config, [TelegramBotApi? given]) {
    _stop();
    final api = given ?? ref.read(telegramBotApiProvider)(config.token);
    _turns = TelegramTurns(ref, api, threadFor: _threadFor);
    final relay = _relay = TelegramPermissionRelay(
      api,
      answer: (id, choice) =>
          ref.read(agentPermissionsProvider.notifier).answer(id, choice),
      log: _log,
    );
    state = TelegramBotOn(config: config, link: MessagingLink.connecting);
    relay.onPermissions(ref.read(agentPermissionsProvider));
    final poll = _poll = TelegramPoll(
      api,
      onUpdate: _onUpdate,
      onLink: _onLink,
    );
    unawaited(poll.run());
  }

  void _stop() {
    _poll?.stop();
    _poll = null;
    _turns = null;
    _relay = null;
  }

  void _onLink(MessagingLink link, String? detail) {
    final current = state;
    if (current is! TelegramBotOn) return;
    final next = TelegramBotOn(
      config: current.config,
      link: link,
      detail: detail,
    );
    if (next == current) return;
    if (link == MessagingLink.notAnswering) {
      _log.warn('telegram', 'the bot is not answering: $detail');
    }
    state = next;
  }

  void _onUpdate(TelegramUpdate update) {
    final current = state;
    final turns = _turns;
    final relay = _relay;
    if (current is! TelegramBotOn || turns == null || relay == null) return;
    final allowed = current.config.allowedUsers;
    switch (update) {
      case TelegramText():
        _onText(update, allowed, turns);
      case TelegramButtonPress(:final fromId):
        if (!allowed.contains('$fromId')) return;
        unawaited(telegramQuietly(_log, relay.onPress(update)));
      case TelegramOtherMessage(
        :final chatId,
        :final fromId,
        :final privateChat,
      ):
        final ok = telegramMayAnswer(
          fromId: fromId,
          privateChat: privateChat,
          allowed: allowed,
        );
        if (ok) turns.note(chatId, 'I can only read text for now — type it?');
      case TelegramIgnored():
        return;
    }
  }

  void _onText(
    TelegramText message,
    List<String> allowed,
    TelegramTurns turns,
  ) {
    final chatId = message.chatId;
    final ok = telegramMayAnswer(
      fromId: message.fromId,
      privateChat: message.privateChat,
      allowed: allowed,
    );
    if (!ok) return _noteStranger(message.fromId);
    if (telegramMessageIsStale(message.sentAt, DateTime.now())) {
      return turns.note(
        chatId,
        "This arrived while Grid was closed, so it wasn't run. Send it again "
        'if you still want it.',
      );
    }
    switch (parseTelegramCommand(message.text)) {
      case TelegramCommand.start:
        turns.note(chatId, _kGreeting);
      case TelegramCommand.fresh:
        unawaited(telegramQuietly(_log, _fresh(chatId, turns)));
      case TelegramCommand.stop:
        turns.stop(chatId, _threadOf(chatId));
      case null:
        turns.ask(message);
    }
  }

  Future<void> _fresh(int chatId, TelegramTurns turns) async {
    await _threadFor(chatId, fresh: true);
    await turns.reply(
      chatId,
      'Started a fresh conversation. The last one is still in Chat on your '
      'computer.',
    );
  }

  String? _threadOf(int chatId) => switch (state) {
    TelegramBotOn(:final config) => config.threadFor(chatId),
    _ => null,
  };

  Future<String> _threadFor(int chatId, {bool fresh = false}) async {
    final current = state;
    if (current is! TelegramBotOn) {
      throw StateError('the Telegram bot was disconnected');
    }
    final existing = current.config.threadFor(chatId);
    if (existing != null && !fresh) return existing;
    final id = telegramConversationId(chatId, DateTime.now());
    final config = current.config.withThread(chatId, id);
    state = TelegramBotOn(
      config: config,
      link: current.link,
      detail: current.detail,
    );
    await _store.write(config);
    return id;
  }

  void _noteStranger(int fromId) {
    if (!_strangers.add(fromId)) return;
    _log.info(
      'telegram',
      'ignored a message from Telegram id $fromId — not on the list',
    );
  }
}
