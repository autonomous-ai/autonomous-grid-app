part of 'telegram_sessions.dart';

/// `/model`: see what the current chat answers with, and change it.
mixin _ModelMenu on _MenuBase {
  /// The models this chat's assistant can answer with, the current one ticked
  /// — or, when [named] names one of them, that model straight away.
  Future<void> model(int chatId, {String named = ''}) async {
    if (turns.busy(chatId)) return _busy(chatId, 'change the model');
    final target = _threads.current(chatId);
    // Waited for, not read: the bot answers with the Chat tab closed, and the
    // grid's list is a request in flight (see [gridServedModels]).
    final served = await gridServedModels(_ref);
    final current = await _modelOf(target, served: served);
    final items = telegramModelItems(
      options: chatModelOptions(
        served,
        agentInstalled: _ref.read(anyAgentInstalledProvider),
      ),
      agent: _agentOf(target),
      current: current,
    );
    if (items.isEmpty) return _noModels(chatId, target, served.isEmpty);
    if (named.isNotEmpty) {
      final wanted = telegramModelNamed(items, named);
      if (wanted != null) return _use(chatId, target, wanted);
      await _api.sendMessage(
        chatId,
        "This grid isn't serving <code>${telegramEscape(named)}</code>. Pick "
        'one it is serving:',
        html: true,
      );
    }
    final id = _nextMenu++;
    final messageId = await _open(
      chatId,
      _modelText(current),
      telegramMenuRows(menu: id, items: items, page: 0),
    );
    _menus[chatId] = _Models(id, messageId, target, items);
  }

  /// Why there is nothing to pick, which is two different problems: the grid is
  /// serving nothing at all, or nothing this chat's assistant can talk to.
  Future<void> _noModels(int chatId, String? target, bool gridEmpty) =>
      _api.sendMessage(
        chatId,
        gridEmpty
            ? "This grid isn't serving a model right now. Start one in Grid on "
                  'your computer, then send /model again.'
            : 'This grid has no model ${_agentOf(target).name} can answer '
                  'with. Start one it can use, or let another assistant take '
                  'this chat in Grid.',
      );

  Future<void> _onModelsTap(
    int chatId,
    _Models menu,
    TelegramMenuTap tap,
  ) async {
    switch (tap) {
      case TelegramPickTap(:final index) when index < menu.items.length:
        await _setModel(chatId, menu.target, menu.items[index].value);
        return _finish(chatId, menu, _setText(menu.items[index].value));
      case TelegramPageTap(:final page):
        return _redraw(
          chatId,
          menu,
          _modelText(await _modelOf(menu.target)),
          telegramMenuRows(menu: menu.id, items: menu.items, page: page),
        );
      default:
        return;
    }
  }

  /// `/model <name>`, with a name the grid serves: set it, and say so in a
  /// message of its own — there is no menu open to turn into the answer.
  Future<void> _use(int chatId, String? target, String model) async {
    await _setModel(chatId, target, model);
    await _api.sendMessage(chatId, _setText(model), html: true);
  }

  String _setText(String model) =>
      '<b>Model set to</b> <code>${telegramEscape(model)}</code> — your next '
      'message in this chat uses it.';

  String _modelText(String current) =>
      '<b>Current model:</b> <code>${telegramEscape(current)}</code>'
      '\n\nPick the model this chat answers with:';

  /// Point [target] at [model]: the Grid chat itself once it has started,
  /// else its draft — and a Telegram chat with no chat yet gets a new one.
  Future<void> _setModel(int chatId, String? target, String model) async {
    if (target == null) {
      await _threads.startNew(chatId, model: model);
      return;
    }
    if (_chat(target) == null) return _threads.setDraftModel(target, model);
    _ref.read(chatSessionsProvider.notifier).setChatModel(target, model);
  }
}
