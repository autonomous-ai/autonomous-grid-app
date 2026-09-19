import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../agents/logic/agent_permissions.dart';
import '../messaging_platform.dart';
import '../messaging_state.dart';
import 'telegram_bot_store.dart';
import 'telegram_menus.dart';
import 'telegram_permission_relay.dart';
import 'telegram_poll.dart';
import 'telegram_rules.dart';
import 'telegram_sessions.dart';
import 'telegram_turns.dart';

const String _kGreeting =
    "Hi! I'm Grid, answering from your computer. Send a message or a picture "
    'and the assistant there replies.\n\n'
    '/sessions picks a project or a chat · /new starts a new chat · /model '
    'changes the model · /stop stops an answer.';

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

/// Runs the bot, and keeps which Grid chat each Telegram chat is in (see
/// [TelegramThreads]) — in its state, and saved with the rest of the bot.
class TelegramBotController extends Notifier<TelegramBotState>
    implements TelegramThreads {
  TelegramPoll? _poll;
  TelegramTurns? _turns;
  TelegramMenus? _menus;
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

  @override
  String? current(int chatId) => _config?.threadFor(chatId);

  @override
  int? chatIdOf(String conversationId) {
    final threads = _config?.threads;
    if (threads == null) return null;
    for (final entry in threads.entries) {
      if (entry.value == conversationId) return int.tryParse(entry.key);
    }
    return null;
  }

  @override
  TelegramDraft? draftFor(String conversationId) =>
      _config?.draftFor(conversationId);

  @override
  Future<void> point(int chatId, String conversationId) =>
      _save((config) => config.withThread(chatId, conversationId));

  @override
  Future<String> startNew(
    int chatId, {
    String? projectId,
    String? model,
  }) async {
    final id = telegramConversationId(chatId, DateTime.now());
    await _save(
      (config) => config.withThread(
        chatId,
        id,
        draft: (projectId: projectId, model: model),
      ),
    );
    return id;
  }

  @override
  Future<void> setDraftModel(String conversationId, String model) =>
      _save((config) {
        final draft = config.draftFor(conversationId);
        return config.withDraft(conversationId, (
          projectId: draft?.projectId,
          model: model,
        ));
      });

  @override
  Future<void> started(String conversationId) =>
      _save((config) => config.withoutDraft(conversationId));

  TelegramBotConfig? get _config => switch (state) {
    TelegramBotOn(:final config) => config,
    _ => null,
  };

  /// Apply [change] to the running bot's config, and save it.
  Future<void> _save(
    TelegramBotConfig Function(TelegramBotConfig config) change,
  ) async {
    final current = state;
    if (current is! TelegramBotOn) {
      throw StateError('the Telegram bot was disconnected');
    }
    final config = change(current.config);
    state = TelegramBotOn(
      config: config,
      link: current.link,
      detail: current.detail,
    );
    await _store.write(config);
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
    final turns = _turns = TelegramTurns(ref, api, threads: this);
    _menus = TelegramMenus(ref, api, turns: turns);
    final relay = _relay = TelegramPermissionRelay(
      api,
      chatIdOf: chatIdOf,
      answer: (id, choice) =>
          ref.read(agentPermissionsProvider.notifier).answer(id, choice),
      log: _log,
    );
    state = TelegramBotOn(config: config, link: MessagingLink.connecting);
    relay.onPermissions(ref.read(agentPermissionsProvider));
    // On every start, not only at connect: a bot connected before a command
    // existed learns it the next time Grid opens.
    _quietly(api.setCommands(kTelegramCommandMenu));
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
    _menus = null;
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
    final allowed = _config?.allowedUsers;
    final turns = _turns;
    final menus = _menus;
    final relay = _relay;
    if (allowed == null || turns == null || menus == null || relay == null) {
      return;
    }
    switch (update) {
      case TelegramText():
        _onText(update, allowed, turns, menus);
      case TelegramButtonPress(:final fromId, :final data):
        if (!allowed.contains('$fromId')) return;
        final tap = parseTelegramMenuTap(data);
        _quietly(
          tap == null ? relay.onPress(update) : menus.onTap(update, tap),
        );
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
        if (ok) {
          turns.note(
            chatId,
            'I can read text and pictures, but not this kind of message yet '
            '— type it?',
          );
        }
      case TelegramIgnored():
        return;
    }
  }

  void _onText(
    TelegramText message,
    List<String> allowed,
    TelegramTurns turns,
    TelegramMenus menus,
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
    // A caption is words about its picture, never a command: a picture that
    // ran `/new` instead of reaching the assistant would simply be lost.
    final command = message.pictureId == null
        ? parseTelegramCommand(message.text)
        : null;
    switch (command) {
      case TelegramCommand.start:
        turns.note(chatId, _kGreeting);
      case TelegramCommand.fresh:
        _quietly(menus.fresh(chatId));
      case TelegramCommand.sessions:
        _quietly(menus.sessions(chatId));
      case TelegramCommand.model:
        _quietly(
          menus.model(chatId, named: telegramCommandArgument(message.text)),
        );
      case TelegramCommand.stop:
        turns.stop(chatId);
      case null:
        turns.ask(message);
    }
  }

  void _quietly(Future<void> work) => unawaited(telegramQuietly(_log, work));

  void _noteStranger(int fromId) {
    if (!_strangers.add(fromId)) return;
    _log.info(
      'telegram',
      'ignored a message from Telegram id $fromId — not on the list',
    );
  }
}
