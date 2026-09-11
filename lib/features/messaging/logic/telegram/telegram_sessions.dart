import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/cli/agent_event.dart';
import '../../../agents/logic/active_chat_agent.dart';
import '../../../agents/logic/agent_catalog.dart';
import '../../../agents/logic/agent_chat_surface.dart';
import '../../../agents/logic/agent_model_support.dart';
import '../../../agents/logic/agent_status.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../chat/logic/conversation.dart';
import '../../../chat/logic/grid_model_catalog.dart';
import '../../../playground/logic/playground_models.dart';
import '../../../playground/logic/playground_request.dart';
import '../../../projects/logic/project.dart';
import '../../../scheduled/logic/task_conversation_id.dart';
import 'telegram_markup.dart';
import 'telegram_menus.dart';
import 'telegram_turns.dart';

part 'telegram_model_menu.dart';
part 'telegram_session_menu.dart';

/// Whether [chat] can be carried on from a phone: live, the user's own (not a
/// scheduled task's or a document's), and drawn as a message list — a terminal
/// chat needs somebody at the keyboard.
bool telegramCanContinue(Conversation chat) =>
    !chat.isArchived &&
    jobIdOfTaskConversation(chat.id) == null &&
    chat.documentPath == null &&
    recordedChatSurface(chat) == AgentChatSurface.list;

/// A place chats live: one project, or (null) the chats outside every project.
typedef _Place = ({String? projectId, String name});

/// What one menu message is showing, so a tap on it can be read back.
sealed class _Menu {
  const _Menu(this.id, this.messageId);

  final int id;
  final int messageId;
}

final class _Places extends _Menu {
  const _Places(super.id, super.messageId, this.places);

  final List<_Place> places;
}

final class _Chats extends _Menu {
  const _Chats(super.id, super.messageId, this.place, this.chats);

  final _Place place;
  final List<String> chats;
}

final class _Models extends _Menu {
  const _Models(super.id, super.messageId, this.target, this.items);

  final String? target;
  final List<TelegramMenuItem> items;
}

/// What every menu shares: the one live menu per Telegram chat, and the
/// messages that open, redraw and close it.
abstract class _MenuBase {
  _MenuBase(this._ref, this._api, this.turns);

  final Ref _ref;
  final TelegramBotApi _api;
  final TelegramTurns turns;

  /// The live menu per Telegram chat; opening another replaces it.
  final Map<int, _Menu> _menus = {};
  int _nextMenu = 1;

  TelegramThreads get _threads => turns.threads;

  Conversation? _chat(String? id) {
    if (id == null) return null;
    for (final chat in _ref.read(chatSessionsProvider).conversations) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  /// The project [target] belongs to — a started chat's own, else its draft's.
  String? _projectOf(String? target) =>
      _chat(target)?.projectId ??
      (target == null ? null : _threads.draftFor(target)?.projectId);

  /// The assistant that answers [target].
  AgentTool _agentOf(String? target) => _ref.read(
    resolvedChatAgentProvider(
      _chat(target)?.agent ??
          _ref.read(chatAgentChoiceProvider(_projectOf(target))),
    ),
  );

  /// The model [target] answers with, as shown.
  String _modelOf(String? target) {
    final model = telegramModelFor(
      _ref,
      chat: _chat(target),
      draft: target == null ? null : _threads.draftFor(target),
    );
    return model.isEmpty ? '(none)' : model;
  }

  /// Send a new menu message and return its id.
  Future<int> _open(int chatId, String text, TelegramKeyboard rows) =>
      _api.sendMessage(chatId, text, html: true, rows: rows);

  /// Redraw the menu message as [next] shows it.
  Future<void> _redraw(
    int chatId,
    _Menu next,
    String text,
    TelegramKeyboard rows,
  ) {
    _menus[chatId] = next;
    return _edit(chatId, next.messageId, text, rows);
  }

  /// Close [menu]: its message becomes [text], with no buttons.
  Future<void> _finish(int chatId, _Menu menu, String text) {
    _menus.remove(chatId);
    return _edit(chatId, menu.messageId, text, const []);
  }

  Future<void> _edit(
    int chatId,
    int messageId,
    String text,
    TelegramKeyboard rows,
  ) async {
    try {
      await _api.editMessage(chatId, messageId, text, html: true, rows: rows);
    } on TelegramRefused catch (error) {
      if (!error.notModified) rethrow;
    }
  }

  Future<void> _busy(int chatId, String verb) => _api.sendMessage(
    chatId,
    "Can't $verb while an answer is being written — /stop it, or wait.",
  );
}

/// `/sessions`, `/new` and `/model`: move a Telegram chat between Grid chats,
/// and pick what answers it — dev-quen-bots' command UX, with the first step
/// it lacked: a project, or the chats outside every project.
class TelegramMenus extends _MenuBase with _SessionMenu, _ModelMenu {
  TelegramMenus(Ref ref, TelegramBotApi api, {required TelegramTurns turns})
    : super(ref, api, turns);

  /// A button on one of these menus was tapped. Every tap is answered, so a
  /// button never spins forever.
  Future<void> onTap(TelegramButtonPress press, TelegramMenuTap tap) async {
    final chatId = press.chatId;
    final menu = _menus[chatId];
    if (menu == null || menu.id != tap.menu) {
      return _api.answerButton(press.callbackId, text: 'Expired, run it again');
    }
    final moves = tap is TelegramPickTap || tap is TelegramNewHereTap;
    if (moves && turns.busy(chatId)) {
      return _api.answerButton(
        press.callbackId,
        text: 'Wait for the current answer to finish',
      );
    }
    await _api.answerButton(press.callbackId, text: _toast(menu, tap));
    return switch (menu) {
      _Places() => _onPlacesTap(chatId, menu, tap),
      _Chats() => _onChatsTap(chatId, menu, tap),
      _Models() => _onModelsTap(chatId, menu, tap),
    };
  }

  String? _toast(_Menu menu, TelegramMenuTap tap) => switch ((menu, tap)) {
    (_Chats(), TelegramPickTap()) => 'Switching...',
    (_Chats(), TelegramNewHereTap()) => 'Creating chat...',
    (_Models(), TelegramPickTap()) => 'Setting model...',
    _ => null,
  };
}
